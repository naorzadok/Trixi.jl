#!/usr/bin/env julia
# =============================================================================
# dat_to_inp.jl
#
# Convert an airfoil coordinate file in the two-surface "Lednicer" `.dat` format
# into a 2D quadrilateral Abaqus `.inp` mesh that can be loaded directly by
# Trixi's `P4estMesh{2}`.
#
# The generated mesh is a drop-in replacement for the downloaded `NACA0012.inp`
# used by `examples/p4est_2d_dgsem/elixir_euler_NACA0012airfoil_mach085.jl`.
# It contains node sets with exactly these boundary names (required by that
# elixir):
#
#     Left, Right, Top, Bottom            (far-field box)
#     AirfoilTop, AirfoilBottom           (airfoil walls)
#
# Usage (command line):
#     julia airfoils/dat_to_inp.jl airfoils/n0012.dat airfoils/n0012.inp
#
# Usage (from the REPL / another script):
#     include("airfoils/dat_to_inp.jl")
#     dat_to_inp("airfoils/n0012.dat", "airfoils/n0012.inp";
#                farfield_halfwidth = 20.0, lc_wall = 0.01, lc_far = 2.0)
#
# Implementation note
# -------------------
# We mesh with the Gmsh Julia API (`using Gmsh`), but we write the `.inp` file
# ourselves from the meshed nodes / quads / physical groups queried through the
# Gmsh API. Writing the file directly (instead of relying on `gmsh.write` + text
# post-processing) gives us full, deterministic control over the exact format
# Trixi's standard-Abaqus reader expects, in particular:
#   * the literal element-section marker `******* E L E M E N T S *************`,
#   * `*ELEMENT, type=CPS4, ELSET=Fluid`  (space after the comma — required),
#   * `*NSET,NSET=<Name>`                 (NO space after the comma — required),
#   * comma-terminated node-id lines inside each node set.
# =============================================================================

import Pkg
# Use the local environment in this folder (where Gmsh is installed) so the
# script is self-contained regardless of which project is currently active.
Pkg.activate(@__DIR__; io = devnull)

using Gmsh

# -----------------------------------------------------------------------------
# 1. Parse the Lednicer two-surface `.dat` file.
# -----------------------------------------------------------------------------
"""
    parse_lednicer_dat(path) -> (upper, lower)

Parse an airfoil `.dat` file in the two-surface Lednicer format and return the
`upper` and `lower` surface point lists as vectors of `(x, y)` tuples.

File layout (see `airfoils/n0012.dat`):

    NACA 0012 AIRFOILS          <- line 1: free-text title, ignored
         66.       66.          <- line 2: two counts  N_upper  N_lower
                                <- blank line
     0.0000000 0.0000000        <- N_upper points, y >= 0, LE (0,0) -> upper TE
     ...
                                <- blank line
     0.0000000 0.0000000        <- N_lower points, y <= 0, LE (0,0) -> lower TE
     ...

Both blocks start at the shared leading edge `(0, 0)` and end at the (blunt)
trailing edge `(1, ±y_te)`. Handles the Fortran-style `-.0042603` notation for
`-0.0042603`.
"""
function parse_lednicer_dat(path::AbstractString)
    rawlines = readlines(path)
    # Indices of all non-empty (non-blank) lines.
    nonempty = [i for i in eachindex(rawlines) if !isempty(strip(rawlines[i]))]
    length(nonempty) >= 3 ||
        error("File `$path` does not look like a Lednicer .dat file (too few lines).")

    # nonempty[1] = title (ignored), nonempty[2] = counts line.
    counts = split(strip(rawlines[nonempty[2]]))
    length(counts) >= 2 ||
        error("Could not read the two surface counts from line: " *
              "`$(rawlines[nonempty[2]])`")
    n_upper = round(Int, parse(Float64, counts[1]))
    n_lower = round(Int, parse(Float64, counts[2]))

    # All remaining non-empty lines are coordinate pairs `x y`.
    coords = Tuple{Float64, Float64}[]
    for i in nonempty[3:end]
        toks = split(strip(rawlines[i]))
        length(toks) >= 2 || continue
        push!(coords, (parse(Float64, toks[1]), parse(Float64, toks[2])))
    end

    length(coords) >= n_upper + n_lower ||
        error("Expected at least $(n_upper + n_lower) coordinate points, " *
              "found $(length(coords)).")

    upper = coords[1:n_upper]
    lower = coords[(n_upper + 1):(n_upper + n_lower)]

    # Robustness: the block with the larger mean-y is the UPPER surface. Swap if
    # a file happens to list the lower surface first.
    mean_y(v) = sum(p -> p[2], v) / length(v)
    if mean_y(upper) < mean_y(lower)
        upper, lower = lower, upper
    end

    return upper, lower
end

# -----------------------------------------------------------------------------
# 2. Build the geometry + mesh with Gmsh and write the `.inp` file.
# -----------------------------------------------------------------------------
"""
    dat_to_inp(dat_path, inp_path; kwargs...)

Read the airfoil `.dat` file at `dat_path`, build a quadrilateral far-field mesh
around it with Gmsh, and write an Abaqus `.inp` mesh at `inp_path` ready for
`P4estMesh{2}`.

Keyword arguments:
  * `farfield_halfwidth = 20.0` : far-field box extent. The box is
        `x ∈ [-fw, 1 + fw]`, `y ∈ [-fw, fw]` (chord on `x ∈ [0, 1]`).
  * `lc_wall = 0.01`            : target element size on the airfoil surface.
        With `order = 2` (curved cells) this can be made much coarser, since
        wall curvature is then carried by the element shape, not by cell count.
  * `lc_far  = 2.0`             : target element size at the far-field box.
  * `order = 1`                 : element order. `1` => linear `CPS4` quads;
        `2` => curved second-order `CPS8` quads. With `order = 2` Gmsh inserts
        mid-edge nodes and places the wall mid-edge nodes *on the spline*, so
        the airfoil is represented exactly with far fewer cells. Trixi's
        standard-Abaqus reader supports both (`CPS4`/`CPS8`).
  * `optimize = true`           : for `order = 2`, run Gmsh's high-order
        optimizer to untangle curved boundary-layer cells (avoids inverted
        elements near the leading edge). Ignored for `order = 1`.
  * `vtk_path = nothing`        : if set to a `.vtk` path, also write the mesh
        in VTK format (via Gmsh) for visualization in ParaView. The `.inp` we
        write uses a custom layout Gmsh cannot re-open, so this is exported
        directly from the live mesh.
  * `verbose = false`           : print Gmsh's own log to the terminal.
"""
function dat_to_inp(dat_path::AbstractString, inp_path::AbstractString;
                    farfield_halfwidth::Real = 20.0,
                    lc_wall::Real = 0.01,
                    lc_far::Real = 2.0,
                    order::Integer = 1,
                    optimize::Bool = true,
                    vtk_path::Union{Nothing, AbstractString} = nothing,
                    verbose::Bool = false)
    order in (1, 2) || error("`order` must be 1 (linear) or 2 (curved); got $order.")
    upper, lower = parse_lednicer_dat(dat_path)

    gmsh.initialize()
    try
        gmsh.option.setNumber("General.Terminal", verbose ? 1 : 0)
        gmsh.model.add("airfoil")
        geo = gmsh.model.geo

        # --- airfoil surface points -----------------------------------------
        # Shared leading-edge point (first point of both surfaces).
        p_le = geo.addPoint(upper[1][1], upper[1][2], 0.0, lc_wall)

        # Upper surface points (LE -> upper TE). p_le is reused as the first.
        pts_upper = Int[p_le]
        for k in 2:length(upper)
            push!(pts_upper, geo.addPoint(upper[k][1], upper[k][2], 0.0, lc_wall))
        end

        # Lower surface points (LE -> lower TE). Skip the duplicate LE point.
        pts_lower = Int[p_le]
        for k in 2:length(lower)
            push!(pts_lower, geo.addPoint(lower[k][1], lower[k][2], 0.0, lc_wall))
        end

        # --- airfoil curves -------------------------------------------------
        spline_upper = geo.addSpline(pts_upper)                 # LE -> upper TE
        spline_lower = geo.addSpline(pts_lower)                 # LE -> lower TE
        # Blunt trailing-edge base: straight line upper TE -> lower TE.
        te_base = geo.addLine(pts_upper[end], pts_lower[end])

        # Closed airfoil contour: upper (LE->TE), TE base (upTE->loTE),
        # then lower reversed (loTE->LE).
        loop_airfoil = geo.addCurveLoop([spline_upper, te_base, -spline_lower])

        # --- far-field box --------------------------------------------------
        fw = float(farfield_halfwidth)
        x_min, x_max = -fw, 1.0 + fw
        y_min, y_max = -fw, fw

        b1 = geo.addPoint(x_min, y_min, 0.0, lc_far)
        b2 = geo.addPoint(x_max, y_min, 0.0, lc_far)
        b3 = geo.addPoint(x_max, y_max, 0.0, lc_far)
        b4 = geo.addPoint(x_min, y_max, 0.0, lc_far)

        l_bottom = geo.addLine(b1, b2)   # y = y_min
        l_right = geo.addLine(b2, b3)    # x = x_max
        l_top = geo.addLine(b3, b4)      # y = y_max
        l_left = geo.addLine(b4, b1)     # x = x_min

        loop_box = geo.addCurveLoop([l_bottom, l_right, l_top, l_left])

        # Fluid surface = box with the airfoil as a hole.
        surf = geo.addPlaneSurface([loop_box, loop_airfoil])

        geo.synchronize()

        # --- physical groups (names must match the elixir exactly) ----------
        # The TE base segment is attached to `AirfoilBottom`: both airfoil names
        # are slip walls in the elixir and the force integral runs over
        # (:AirfoilBottom, :AirfoilTop), so the closed body surface is covered.
        pg_airfoil_top = gmsh.model.addPhysicalGroup(1, [spline_upper], -1, "AirfoilTop")
        pg_airfoil_bot = gmsh.model.addPhysicalGroup(1, [spline_lower, te_base], -1,
                                                     "AirfoilBottom")
        pg_left = gmsh.model.addPhysicalGroup(1, [l_left], -1, "Left")
        pg_right = gmsh.model.addPhysicalGroup(1, [l_right], -1, "Right")
        pg_top = gmsh.model.addPhysicalGroup(1, [l_top], -1, "Top")
        pg_bottom = gmsh.model.addPhysicalGroup(1, [l_bottom], -1, "Bottom")
        gmsh.model.addPhysicalGroup(2, [surf], -1, "Fluid")

        boundary_groups = [("Left", pg_left), ("Right", pg_right),
                           ("Top", pg_top), ("Bottom", pg_bottom),
                           ("AirfoilTop", pg_airfoil_top),
                           ("AirfoilBottom", pg_airfoil_bot)]

        # --- mesh (force all-quad: p4est cannot use triangles) --------------
        gmsh.option.setNumber("Mesh.RecombineAll", 1)
        # Blossom recombination -> full-quad meshes on clean domains.
        gmsh.option.setNumber("Mesh.RecombinationAlgorithm", 1)
        gmsh.option.setNumber("Mesh.Algorithm", 8)  # Frontal-Delaunay for quads
        gmsh.model.mesh.generate(2)

        # Guard against any leftover triangles (element type 2).
        tri_tags, _ = gmsh.model.mesh.getElementsByType(2)
        if !isempty(tri_tags)
            # Force an all-quad subdivision and re-mesh.
            gmsh.option.setNumber("Mesh.SubdivisionAlgorithm", 1)
            gmsh.model.mesh.generate(2)
            tri_tags, _ = gmsh.model.mesh.getElementsByType(2)
            isempty(tri_tags) ||
                error("Mesh still contains $(length(tri_tags)) triangles; " *
                      "p4est requires an all-quad mesh.")
        end

        # Promote to curved (second-order) elements if requested. This inserts
        # mid-edge nodes; on the airfoil splines they land on the true geometry,
        # so the wall is represented exactly even with a coarse cell count.
        if order == 2
            # Serendipity (8-node, type 16) quads -> Abaqus `CPS8`. Without this,
            # Gmsh emits 9-node (type 10) quads with an extra center node.
            gmsh.option.setNumber("Mesh.SecondOrderIncomplete", 1)
            gmsh.model.mesh.setOrder(2)
            if optimize
                # 2 = elastic + optimization: untangle curved boundary-layer cells.
                gmsh.option.setNumber("Mesh.HighOrderOptimize", 2)
                gmsh.model.mesh.optimize("HighOrderElastic")
            end
        end

        # --- query mesh entities --------------------------------------------
        # NOTE: query nodes *after* `setOrder`, so mid-edge nodes are included.
        node_tags, node_coords, _ = gmsh.model.mesh.getNodes()
        # Contiguous 1..N renumbering (Gmsh tags may be non-contiguous).
        old_to_new = Dict{Int, Int}()
        for (i, t) in enumerate(node_tags)
            old_to_new[Int(t)] = i
        end
        n_nodes = length(node_tags)

        # Quads: Gmsh element type 3 = 4-node linear, type 16 = 8-node quadratic.
        # The connectivity order matches Abaqus CPS4/CPS8 (4 corners, then the
        # 4 mid-edge nodes for CPS8), which is exactly what Trixi's reader wants.
        gmsh_quad_type = order == 2 ? 16 : 3
        nodes_per_quad = order == 2 ? 8 : 4
        elem_type = order == 2 ? "CPS8" : "CPS4"
        quad_tags, quad_conn = gmsh.model.mesh.getElementsByType(gmsh_quad_type)
        n_quads = length(quad_tags)
        n_quads > 0 || error("No quadrilateral elements were generated.")

        # Boundary node sets, renumbered to the new contiguous ids. For curved
        # meshes these include the mid-edge nodes on each boundary curve; that is
        # harmless for boundary assignment (which only checks element corners)
        # and ensures the curved wall nodes are present.
        nodesets = Dict{String, Vector{Int}}()
        for (name, ptag) in boundary_groups
            ntags, _ = gmsh.model.mesh.getNodesForPhysicalGroup(1, ptag)
            ids = sort!(unique!([old_to_new[Int(t)] for t in ntags]))
            nodesets[name] = ids
        end

        # --- write the Abaqus `.inp` file -----------------------------------
        write_inp(inp_path, node_coords, n_nodes, quad_conn, n_quads,
                  nodes_per_quad, elem_type, old_to_new, boundary_groups, nodesets)

        # --- optional VTK export for ParaView -------------------------------
        if vtk_path !== nothing
            gmsh.write(String(vtk_path))
            println("Wrote VTK : ", vtk_path)
        end

        # --- summary --------------------------------------------------------
        println("Wrote mesh: ", inp_path)
        println("  element type : ", elem_type, order == 2 ? " (curved)" : " (linear)")
        println("  nodes        : ", n_nodes)
        println("  quad elements: ", n_quads)
        println("  node sets    : ",
                join([string(name, " (", length(nodesets[name]), ")")
                      for (name, _) in boundary_groups], ", "))
        return inp_path
    finally
        gmsh.finalize()
    end
end

# -----------------------------------------------------------------------------
# 3. Write the `.inp` file in the exact format Trixi's standard-Abaqus reader
#    (`src/meshes/p4est_mesh.jl`) expects.
# -----------------------------------------------------------------------------
function write_inp(inp_path, node_coords, n_nodes, quad_conn, n_quads,
                   nodes_per_quad, elem_type, old_to_new, boundary_groups, nodesets)
    open(inp_path, "w") do io
        println(io, "*HEADING")
        println(io, " Mesh generated by airfoils/dat_to_inp.jl (Trixi/p4est)")

        # Nodes: `id, x, y, z`. `node_coords` is a flat [x1,y1,z1, x2,y2,z2, ...].
        println(io, "*NODE")
        for i in 1:n_nodes
            x = node_coords[3 * (i - 1) + 1]
            y = node_coords[3 * (i - 1) + 2]
            z = node_coords[3 * (i - 1) + 3]
            println(io, i, ", ", x, ", ", y, ", ", z)
        end

        # Element-section marker (exact string the reader searches for).
        println(io, "******* E L E M E N T S *************")
        # `CPS4` (linear, 4 nodes) or `CPS8` (curved, 8 nodes). The space after
        # the comma in `*ELEMENT, type=` is required by the reader's regex; the
        # connectivity is written with `, ` separators (the reader splits on
        # `,\s+`). For CPS8 the order is 4 corners then 4 mid-edge nodes.
        println(io, "*ELEMENT, type=", elem_type, ", ELSET=Fluid")
        for e in 1:n_quads
            base = nodes_per_quad * (e - 1)
            ids = (old_to_new[Int(quad_conn[base + k])] for k in 1:nodes_per_quad)
            println(io, e, ", ", join(ids, ", "))
        end

        # Boundary node sets. The reader requires `*NSET,NSET=` with NO space
        # after the comma, and comma-terminated id lines.
        for (name, _) in boundary_groups
            ids = nodesets[name]
            println(io, "*NSET,NSET=", name)
            # Wrap ids, 10 per line, every line terminated by a comma.
            i = 1
            while i <= length(ids)
                j = min(i + 9, length(ids))
                println(io, join(ids[i:j], ", "), ",")
                i = j + 1
            end
        end
    end
    return inp_path
end

# -----------------------------------------------------------------------------
# Command-line entry point.
# -----------------------------------------------------------------------------
if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) < 2
        println("Usage: julia airfoils/dat_to_inp.jl <input.dat> <output.inp> " *
                "[farfield_halfwidth] [lc_wall] [lc_far] [order] [vtk_path]")
        exit(1)
    end
    dat_path = ARGS[1]
    inp_path = ARGS[2]
    kwargs = Dict{Symbol, Any}()
    length(ARGS) >= 3 && (kwargs[:farfield_halfwidth] = parse(Float64, ARGS[3]))
    length(ARGS) >= 4 && (kwargs[:lc_wall] = parse(Float64, ARGS[4]))
    length(ARGS) >= 5 && (kwargs[:lc_far] = parse(Float64, ARGS[5]))
    length(ARGS) >= 6 && (kwargs[:order] = parse(Int, ARGS[6]))
    if length(ARGS) >= 7
        kwargs[:vtk_path] = ARGS[7]
    else
        # Default: write a sibling `.vtk` next to the `.inp` for ParaView.
        kwargs[:vtk_path] = replace(inp_path, r"\.inp$" => "") * ".vtk"
    end
    dat_to_inp(dat_path, inp_path; kwargs...)
end

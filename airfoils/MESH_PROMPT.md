# Agent Task Prompt: Build an airfoil `.inp` mesh from a `.dat` file for Trixi/p4est

## 1. Goal / what is needed

I have an airfoil coordinate file `airfoils/n0012.dat` (NACA 0012, with a **blunt
trailing edge**). I want a **Julia script** that:

- reads such a `.dat` file (this one, or any other file in the **same format**),
- builds a 2D quadrilateral mesh around the airfoil inside a rectangular far-field box
  using the **Gmsh Julia API** (`using Gmsh`),
- exports an **Abaqus `.inp`** file that can be loaded directly by Trixi's
  `P4estMesh{2}(meshfile; boundary_symbols = ...)`.

The end purpose: load the generated `.inp` into the existing elixir
`examples/p4est_2d_dgsem/elixir_euler_NACA0012airfoil_mach085.jl` (compressible Euler,
Mach 0.85, AMR) **in place of the downloaded `NACA0012.inp`**, run it, and confirm the
results (lift/drag, flow field) are consistent with the reference run. So the mesh must
be a drop-in replacement.

**Hard requirement — boundary names must match the elixir exactly.** That elixir assigns
boundary conditions and force integrals using these names:

- Far field: `Left`, `Right`, `Top`, `Bottom`
- Airfoil: `AirfoilTop`, `AirfoilBottom`

The generated `.inp` must contain node sets with **exactly** these names (no others, no
hyphens — Trixi turns them into Julia `Symbol`s, and `:` symbols cannot contain `-`).

## 2. Deliverable: a `.jl` script in `airfoils/`

Create `airfoils/dat_to_inp.jl` with roughly this interface:

```julia
# Usage:
#   julia airfoils/dat_to_inp.jl airfoils/n0012.dat airfoils/n0012.inp
# or call the function directly:
#   dat_to_inp("airfoils/n0012.dat", "airfoils/n0012.inp";
#              farfield_halfwidth = 20.0, lc_wall = 0.01, lc_far = 2.0)
```

Requirements for the script:

1. Use `using Gmsh` (the Gmsh Julia API), **not** a hand-written `.geo` file.
2. Parse the `.dat` (see section 3 for the exact format and rules).
3. Build geometry:
   - one `Spline` through the **upper** surface points (LE → upper TE),
   - one `Spline` through the **lower** surface points (LE → lower TE),
   - one straight `Line` for the **blunt TE base** connecting upper TE → lower TE,
   - a rectangular far-field box (4 `Line`s). Center the airfoil (chord on `x ∈ [0,1]`);
     make the box large, e.g. `x ∈ [-farfield_halfwidth, 1 + farfield_halfwidth]`,
     `y ∈ [-farfield_halfwidth, farfield_halfwidth]` (default `farfield_halfwidth = 20`).
   - one `PlaneSurface` = far-field loop **minus** the airfoil loop (airfoil is a hole).
4. Force **quad** elements (p4est cannot use triangles):
   `gmsh.option.setNumber("Mesh.RecombineAll", 1)`. Quads must export as `CPS4`.
5. Mesh sizing: fine near the wall (`lc_wall`), coarse at far field (`lc_far`).
   Optionally add a `BoundaryLayer` mesh field on the airfoil curves for wall-normal
   stretching — keep it optional/parameterized.
6. Define **physical groups** (dimension 1 = curves) named exactly:
   - `AirfoilTop`  = upper spline
   - `AirfoilBottom` = lower spline **and** the TE base line
     (document this choice in a comment; the base belongs to the body and both names are
     slip walls in the elixir, so attaching the small base segment to `AirfoilBottom` is
     consistent and keeps the force integral over `(:AirfoilBottom, :AirfoilTop)` closed)
   - `Left` = box edge at `x = x_min`
   - `Right` = box edge at `x = x_max`
   - `Top` = box edge at `y = y_max`
   - `Bottom` = box edge at `y = y_min`
   - also add a dimension-2 physical group for the fluid surface (any name, e.g. `Fluid`).
7. Export node sets, not just element sets. In Gmsh that means:
   - `gmsh.option.setNumber("Mesh.SaveGroupsOfNodes", 1)`
   - write with `gmsh.write(output_path)` where `output_path` ends in `.inp`.
8. **Verify Trixi-reader compatibility before finishing** (this is the usual failure
   point):
   - Open Trixi's parser at `src/meshes/p4est_mesh.jl`, function `parse_node_sets`. It
     looks for lines that start **literally** with `*NSET,NSET=` (no space after the
     comma) and reads `Symbol(split(line, "=")[2])` as the boundary name.
   - Gmsh may export `*NSET, NSET=Name` (with a space) or include extra qualifiers.
     After `gmsh.write`, **read the `.inp` back and post-process** the text so every
     node-set header is exactly `*NSET,NSET=<Name>` with the names from step 6, and
     remove any hyphens in names. Make the rewrite robust (regex), then overwrite the file.
   - Confirm the element header is `*ELEMENT, type=CPS4` (linear quads). Trixi's standard
     Abaqus reader supports `CPS4` (linear) and `CPS8` (quadratic) quads.
9. Print a short summary at the end: number of nodes, number of quad elements, the list of
   node-set names found, and the output path.

After generating, the user should be able to do, inside the elixir:

```julia
mesh_file = joinpath(@__DIR__, "..", "..", "airfoils", "n0012.inp")
boundary_symbols = [:Left, :Right, :Top, :Bottom, :AirfoilTop, :AirfoilBottom]
mesh = P4estMesh{2}(mesh_file, boundary_symbols = boundary_symbols)
```

with the existing `boundary_conditions = (; Left = ..., Right = ..., Top = ..., Bottom = ...,
AirfoilBottom = ..., AirfoilTop = ...)` unchanged.

## 3. How to parse the `.dat` file (Lednicer / two-surface format)

I looked at `airfoils/n0012.dat`. The exact layout is:

```
 NACA 0012 AIRFOILS              <- line 1: free-text title, ignore it
      66.       66.             <- line 2: two floats = N_upper  N_lower
                                 <- blank line
 0.0000000 0.0000000            <- upper surface point 1  (Leading Edge, y = 0)
 0.0005839 0.0042603            <- upper surface point 2  (y > 0)
 ...                            <- ... N_upper points total, y >= 0
 1.0000000 0.0012600            <- upper surface point N_upper (upper Trailing Edge)
                                 <- blank line
 0.0000000 0.0000000            <- lower surface point 1  (Leading Edge, y = 0)
 0.0005839 -.0042603            <- lower surface point 2  (y < 0)
 ...                            <- ... N_lower points total, y <= 0
 1.0000000 -.0012600            <- lower surface point N_lower (lower Trailing Edge)
```

Parsing rules the agent must follow:

1. **Skip line 1** (title text).
2. **Line 2** holds two numbers (`66. 66.`). Parse them as the counts
   `N_upper` and `N_lower`. (They are written as floats with a trailing dot — parse as
   `Float64` then `round(Int, ...)`, or strip the dot.) Do not assume both are equal;
   read them.
3. The remaining numeric lines are coordinate pairs `x y`. Note the file uses the
   Fortran-style `-.0042603` for `-0.0042603`; parsing must handle a leading `-.`.
   (`parse(Float64, "-.0042603")` works in Julia, but be safe with whitespace splitting.)
4. **Blank lines separate the blocks.** Read `N_upper` coordinate lines for the upper
   surface, then `N_lower` coordinate lines for the lower surface. Prefer to drive the
   split by the counts on line 2; you may also use blank lines as a secondary check.
5. **Orientation / which surface is which:** in this format the **first block has
   `y ≥ 0` → it is the UPPER surface**, and the **second block has `y ≤ 0` → it is the
   LOWER surface**. Both blocks run from the **Leading Edge `(0,0)`** to the
   **Trailing Edge `(1, ±y_te)`**. Do not assume a single TE→TE loop (that would be Selig
   format); this is the two-surface Lednicer format.
   - To be format-robust, after reading, you may confirm orientation by the **mean
     `y`** of each block (positive mean ⇒ upper) and swap if a file lists lower first.
6. **Shared leading-edge point:** the first point of the upper block `(0,0)` and the first
   point of the lower block `(0,0)` are the **same physical point**. When you build the
   closed contour, include it only once (e.g. upper points `1..N_upper`, then lower points
   `N_lower..2`, skipping the duplicate LE).
7. **Blunt trailing edge:** the last upper point `(1, +y_te)` and last lower point
   `(1, -y_te)` are **different** points (gap = `2*y_te`). Insert a straight **TE base
   line** between them. This is the corner/blunt-TE handling — it is two slope corners
   plus a short straight base, *not* a discontinuity that prevents meshing.
8. Closed airfoil loop order (counter-clockwise or clockwise is fine as long as it is
   consistent and the surface normal points into the fluid via the `PlaneSurface` hole):
   `[upper spline (LE→TE)] → [TE base line (upper TE→lower TE)] → [lower spline (TE→LE)]`.

## 4. Acceptance checks

- Script runs: `julia airfoils/dat_to_inp.jl airfoils/n0012.dat airfoils/n0012.inp`
  produces `airfoils/n0012.inp` with no errors.
- `P4estMesh{2}("airfoils/n0012.inp", boundary_symbols = [:Left,:Right,:Top,:Bottom,
  :AirfoilTop,:AirfoilBottom])` loads without warnings about missing nodesets.
- The modified elixir runs to completion and produces lift/drag and a flow field
  qualitatively matching the reference `NACA0012.inp` run (same free stream, AMR).
- Report any spacing/format edits that were needed in the `.inp` for Trixi to accept it.

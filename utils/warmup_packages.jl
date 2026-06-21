#!/usr/bin/env julia

using Pkg
using SHA

const DEFAULT_PACKAGE_FILE = joinpath(@__DIR__, "startup_packages.txt")

function print_help()
    println("""
Warm up Julia packages by loading them once.

Usage:
  julia utils/warmup_packages.jl [options]

Options:
  --file=PATH       Package list file (default: utils/startup_packages.txt)
  --project=PATH    Activate this project/environment before warming up
    --cache-file=PATH Cache marker file (default: <project>/.warmup_cache)
    --use-cache       Skip warmup when cache marker is valid
    --force           Ignore cache and force warmup
    --add-missing     Auto-add missing packages to the active project
  --no-add          Do not auto-add missing packages
  --dry-run         Print what would be done without loading packages
  --help            Show this help message

Package list format:
  One package name per line. Empty lines and lines starting with # are ignored.
""")
end

function parse_args(args)
    package_file = DEFAULT_PACKAGE_FILE
    project_path = nothing
    cache_file = nothing
    use_cache = false
    force = false
    auto_add_missing = false
    dry_run = false

    for arg in args
        if arg == "--help"
            print_help()
            return nothing
        elseif startswith(arg, "--file=")
            package_file = split(arg, "=", limit = 2)[2]
        elseif startswith(arg, "--project=")
            project_path = split(arg, "=", limit = 2)[2]
        elseif startswith(arg, "--cache-file=")
            cache_file = split(arg, "=", limit = 2)[2]
        elseif arg == "--use-cache"
            use_cache = true
        elseif arg == "--force"
            force = true
        elseif arg == "--add-missing"
            auto_add_missing = true
        elseif arg == "--no-add"
            auto_add_missing = false
        elseif arg == "--dry-run"
            dry_run = true
        else
            error("Unknown argument: $arg. Use --help for usage.")
        end
    end

    return (; package_file, project_path, cache_file, use_cache, force, auto_add_missing, dry_run)
end

function read_package_list(path)
    if !isfile(path)
        error("Package list file not found: $path")
    end

    names = String[]
    for line in eachline(path)
        entry = strip(line)
        if isempty(entry) || startswith(entry, "#")
            continue
        end
        push!(names, entry)
    end

    return unique(names)
end

function ensure_package_available(pkg::String; auto_add_missing::Bool)
    if Base.find_package(pkg) !== nothing
        return
    end

    if !auto_add_missing
        error("Package '$pkg' is not available in current environment/load path")
    end

    @info "Adding missing package" package = pkg
    Pkg.add(pkg)
end

function load_package(pkg::String)
    sym = Symbol(pkg)
    @info "Loading package" package = pkg
    Core.eval(Main, :(using $sym))
end

function file_sha1(path::AbstractString)
    if !isfile(path)
        return "missing"
    end
    return bytes2hex(open(sha1, path))
end

function compute_cache_signature(project_path::AbstractString, package_file::AbstractString)
    project_toml = joinpath(project_path, "Project.toml")
    manifest_toml = joinpath(project_path, "Manifest.toml")
    return string(
        "julia=", VERSION,
        "\nproject=", abspath(project_path),
        "\nproject_toml_sha1=", file_sha1(project_toml),
        "\nmanifest_toml_sha1=", file_sha1(manifest_toml),
        "\npackage_file_sha1=", file_sha1(abspath(package_file)),
        "\n",
    )
end

function cache_is_valid(cache_file::String, signature::String)
    if !isfile(cache_file)
        return false
    end
    return read(cache_file, String) == signature
end

function write_cache(cache_file::String, signature::String)
    mkpath(dirname(cache_file))
    write(cache_file, signature)
end

function package_specific_warmup(packages::Vector{String})
    if "Trixi" in packages
        @info "Running lightweight Trixi warmup"
        if isdefined(Main, :Trixi) && hasproperty(Main.Trixi, :default_example)
            Main.Trixi.default_example()
        end
    end

    if "Plots" in packages
        @info "Running lightweight Plots warmup"
        if isdefined(Main, :Plots)
            Main.Plots.backend()
            Main.Plots.plot(1:2, [0.0, 1.0])
        end
    end
end

function main(args)
    config = parse_args(args)
    isnothing(config) && return

    project_path = isnothing(config.project_path) ? pwd() : abspath(config.project_path)
    cache_file = isnothing(config.cache_file) ? joinpath(project_path, ".warmup_cache") : abspath(config.cache_file)

    @info "Activating project" path = project_path
    Pkg.activate(project_path)

    @info "Instantiating project dependencies"
    Pkg.instantiate()

    packages = read_package_list(config.package_file)
    signature = compute_cache_signature(project_path, config.package_file)

    if config.use_cache && !config.force && cache_is_valid(cache_file, signature)
        @info "Warmup cache is valid; skipping warmup" cache_file = cache_file
        return
    end

    @info "Warmup package list loaded" file = config.package_file count = length(packages)

    if config.dry_run
        println("Packages to warm up:")
        for pkg in packages
            println("  - ", pkg)
        end
        println("Cache file: ", cache_file)
        println("Use cache: ", config.use_cache)
        return
    end

    start_time = time()

    for pkg in packages
        ensure_package_available(pkg; auto_add_missing = config.auto_add_missing)
        load_package(pkg)
    end

    package_specific_warmup(packages)

    # Run Pkg.precompile at the end to ensure any newly added packages are precompiled.
    Pkg.precompile()
    write_cache(cache_file, signature)

    elapsed = round(time() - start_time; digits = 2)
    @info "Warmup complete" packages = length(packages) seconds = elapsed cache_file = cache_file
end

main(ARGS)

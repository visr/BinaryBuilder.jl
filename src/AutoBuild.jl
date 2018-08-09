export build_tarballs, autobuild, print_buildjl, product_hashes_from_github_release
import GitHub: gh_get_json, DEFAULT_API
import SHA: sha256

"""
    build_tarballs(ARGS, src_name, src_version, sources, script, platforms,
                   products, dependencies)

This should be the top-level function called from a `build_tarballs.jl` file.
It takes in the information baked into a `build_tarballs.jl` file such as the
`sources` to download, the `products` to build, etc... and will automatically
download, build and package the tarballs, generating a `build.jl` file when
appropriate.  Note that `ARGS` should be the top-level Julia `ARGS` command-
line arguments object.  This function does some rudimentary parsing of the
`ARGS`, call it with `--help` in the `ARGS` to see what it can do.
"""
function build_tarballs(ARGS, src_name, src_version, sources, script,
                        platforms, products, dependencies)
    # See if someone has passed in `--help`, and if so, give them the
    # assistance they so clearly long for
    if "--help" in ARGS
        println(strip("""
        Usage: build_tarballs.jl [target1,target2,...] [--only-buildjl]
                                 [--verbose] [--help]

        Options:
            targets         By default `build_tarballs.jl` will build a tarball
                            for every target within the `platforms` variable.
                            To override this, pass in a list of comma-separated
                            target triplets for each target to be built.  Note
                            that this can be used to build for platforms that
                            are not listed in the 'default list' of platforms
                            in the build_tarballs.jl script.

            --part=n/m      For breaking up long builds into multiple jobs,
                            divides the `platforms` list into `m` roughly
                            equal parts and then only builds part `n`
                            (`1 ≤ n ≤ m`).  (Does not produce `build.jl`,
                            which must be generated by a later
                            `--only-buildjl` stage.)

            --verbose       This streams compiler output to stdout during the
                            build which can be very helpful for finding bugs.
                            Note that it is colorized if you pass the
                            --color=yes option to julia, see examples below.

            --debug         This causes a failed build to drop into an
                            interactive bash shell for debugging purposes.

            --only-buildjl  This disables building of any tarballs, and merely
                            reconstructs a `build.jl` file from a github
                            release.  This is mostly useful as a later stage in
                            a travis/github releases autodeployment setup.

            --help          Print out this message.

        Examples:
            julia --color=yes build_tarballs.jl --verbose
                This builds all tarballs, with colorized output.

            julia build_tarballs.jl x86_64-linux-gnu,i686-linux-gnu
                This builds two tarballs for the two platforms given, with a
                minimum of output messages.
        """))
        return nothing
    end

    function check_flag(flag)
        flag_present = flag in ARGS
        ARGS = filter!(x -> x != flag, ARGS)
        return flag_present
    end

    # This sets whether we should build verbosely or not
    verbose = check_flag("--verbose")

    # This sets whether we drop into a debug shell on failure or not
    debug = check_flag("--debug")

    # This flag skips actually building and instead attempts to reconstruct a
    # build.jl from a GitHub release page.  Use this to automatically deploy a
    # build.jl file even when sharding targets across multiple CI builds.
    only_buildjl = check_flag("--only-buildjl")

    # --part=n/m builds only part n out of m divisions
    # of the platforms list.
    i = Compat.findlast(x -> startswith(x, "--part="), ARGS)
    should_override_platforms = i !== nothing
    if should_override_platforms
        if i != Compat.findfirst(x -> startswith(x, "--part="), ARGS)
            error("multiple --part arguments are not allowed")
        end
        p = parse.(Int, split(ARGS[i][8:end], '/'))
        (length(p) == 2 && p[2] > 0 && 1 ≤ p[1] ≤ p[2]) || error("invalid argument ", ARGS[i])
        n = (length(platforms) + p[2]-1) ÷ p[2]
        platforms = platforms[n*(p[1]-1)+1:min(end,n*p[1])]
        deleteat!(ARGS, i)
    end

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    if length(ARGS) > 0
        should_override_platforms = true
        platforms = platform_key.(split(ARGS[1], ","))
    end

    # If we're running on CI (Travis, GitLab CI, etc...) and this is a
    # tagged release, automatically determine bin_path by building up a URL
    repo = get_repo_name()
    tag = get_tag_name()

    product_hashes = if !only_buildjl
        # If the user didn't just ask for a `build.jl`, go ahead and actually build
        Compat.@info("Building for $(join(triplet.(platforms), ", "))")

        # Build the given platforms using the given sources
        autobuild(pwd(), src_name, src_version, sources, script, platforms,
                         products, dependencies; verbose=verbose, debug=debug)
    else
        msg = strip("""
        Reconstructing product hashes from GitHub Release $(repo)/$(tag)
        """)
        Compat.@info(msg)

        # Reconstruct product_hashes from github
        product_hashes_from_github_release(repo, tag;
            product_filter="v$(src_version)",
            verbose=verbose
        )
    end

    # If we didn't override the default set of platforms OR we asked for only
    # a build.jl file, then write one out.  We don't write out when overriding
    # the default set of platforms because that is typically done either while
    # testing, or when we have sharded our tarball construction over multiple
    # invocations.
    if !should_override_platforms || only_buildjl
        # The location the binaries will be available from
        bin_path = "https://github.com/$(repo)/releases/download/$(tag)"

        # A dummy prefix to pass through products()
        dummy_products = products(Prefix(pwd()))
        print_buildjl(pwd(), src_name, src_version, dummy_products,
                      product_hashes, bin_path)

        if verbose
            Compat.@info("Writing out the following reconstructed build.jl:")
            print_buildjl(Base.stdout, dummy_products, product_hashes, bin_path)
        end
    end

    return product_hashes
end

function build_tarballs(ARGS, src_name, sources, script, platforms, products,
                        dependencies)
    Compat.@warn("build_tarballs now requires a src_version parameter; assuming v\"1.0.0\"")
    return build_tarballs(
        ARGS,
        src_name,
        v"1.0.0",
        sources,
        script,
        platforms,
        products,
        dependencies
    )
end

# Helper function to get things from ENV, returning `nothing`
# if they either don't exist or are empty
function get_ENV(key)
    if !haskey(ENV, key)
        return nothing
    end

    if isempty(ENV[key])
        return nothing
    end

    return ENV[key]
end

function get_repo_name()
    # Helper function to synthesize repository slug from environment variables
    function get_gitlab_repo_name()
        owner = get_ENV("CI_REPO_OWNER")
        name = get_ENV("CI_REPO_NAME")
        if owner != nothing && name != nothing
            return "$(owner)/$(name)"
        end
        return nothing
    end

    # Helper function to guess repository slug from git remote URL
    function read_git_origin()
        try
            repo = LibGit2.GitRepo(".")
            url = LibGit2.url(LibGit2.get(LibGit2.GitRemote, repo, "origin"))
            owner = basename(dirname(url))
            if occursin(":", owner)
                owner = owner[findlast(owner, ':')+1:end]
            end
            name = basename(url)
            if endswith(name, ".git")
                name = name[1:end-4]
            end
            return "$(owner)/$(name)"
        catch
        end
        return nothing
    end

    return something(
        get_ENV("TRAVIS_REPO_SLUG"),
        get_gitlab_repo_name(),
        read_git_origin(),
        "<repo owner>/<repo name>",
    )
end

function get_tag_name()
    # Helper function to guess tag from current commit taggedness
    function read_git_tag()
        try
            repo = LibGit2.GitRepo(".")
            head_gitsha = LibGit2.GitHash(LibGit2.head(repo))
            for tag in LibGit2.tag_list(repo)
                tag_gitsha = LibGit2.GitHash(LibGit2.GitCommit(repo, tag))
                if head_gitsha == tag_gitsha
                    return tag
                end
            end
        catch
        end
        return nothing
    end

    return something(
        get_ENV("TRAVIS_TAG"),
        get_ENV("CI_COMMIT_TAG"),
        read_git_tag(),
        "<tag>",
    )
end

"""
    autobuild(dir::AbstractString, src_name::AbstractString,
              src_version::VersionNumber, sources::Vector,
              script::AbstractString, platforms::Vector,
              products::Function, dependencies::Vector;
              verbose::Bool = true, debug::Bool = false)

Runs the boiler plate code to download, build, and package a source package
for a list of platforms.  `src_name` represents the name of the source package
being built (and will set the name of the built tarballs), `platforms` is a
list of platforms to build for, `sources` is a list of tuples giving
`(url, hash)` of all sources to download and unpack before building begins,
`script` is a string representing a `bash` script to run to build the desired
products, which are listed as `Product` objects within the vector returned by
the `products` function. `dependencies` gives a list of dependencies that
provide `build.jl` files that should be installed before building begins to
allow this build process to depend on the results of another build process.
Setting `debug` to `true` will cause a failed build to drop into an interactive
shell so that the build can be inspected easily.
"""
function autobuild(dir::AbstractString,
                   src_name::AbstractString,
                   src_version::VersionNumber,
                   sources::Vector,
                   script::AbstractString,
                   platforms::Vector,
                   products::Function,
                   dependencies::Vector;
                   verbose::Bool = true, debug::Bool = false)
    # If we're on CI and we're not verbose, schedule a task to output a "." every few seconds
    if (haskey(ENV, "TRAVIS") || haskey(ENV, "CI")) && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            Compat.@info("Brewing a pot of coffee for Travis...")
            while run_travis_busytask
                sleep(4)
                print(".")
            end
        end
    end

    # This is what we'll eventually return
    product_hashes = Dict()

    # If we end up packaging any local directories into tarballs, we'll store them here
    mktempdir() do tempdir
        # First, download the source(s), store in ./downloads/
        downloads_dir = joinpath(dir, "downloads")
        try mkpath(downloads_dir) catch; end

        # We must prepare our sources.  Download them, hash them, etc...
        sources = Any[s for s in sources]
        for idx in 1:length(sources)
            # If the given source is a local path that is a directory, package it up and insert it into our sources
            if typeof(sources[idx]) <: AbstractString
                if !isdir(sources[idx])
                    error("Sources must either be a pair (url => hash) or a local directory")
                end

                # Package up this directory and calculate its hash
                tarball_path = joinpath(tempdir, basename(sources[idx]) * ".tar.gz")
                package(sources[idx], tarball_path; verbose=verbose)
                tarball_hash = open(tarball_path, "r") do f
                    bytes2hex(sha256(f))
                end

                # Now that it's packaged, store this into sources[idx]
                sources[idx] = (tarball_path => tarball_hash)
            elseif typeof(sources[idx]) <: Pair
                src_url, src_hash = sources[idx]

                # If it's a .git url, clone it
                if endswith(src_url, ".git")
                    src_path = joinpath(downloads_dir, basename(src_url))
                    if !isdir(src_path)
                        repo = LibGit2.clone(src_url, src_path; isbare=true)
                    else
                        LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                            LibGit2.fetch(repo)
                        end
                    end
                else
                    if isfile(src_url)
                        # Immediately abspath() a src_url so we don't lose track of
                        # sources given to us with a relative path
                        src_path = abspath(src_url)

                        # And if this is a locally-sourced tarball, just verify
                        verify(src_path, src_hash; verbose=verbose)
                    else
                        # Otherwise, download and verify
                        src_path = joinpath(downloads_dir, basename(src_url))
                        download_verify(src_url, src_hash, src_path; verbose=verbose)
                    end
                end

                # Now that it's downloaded, store this into sources[idx]
                sources[idx] = (src_path => src_hash)
            else
                error("Sources must be either a `URL => hash` pair, or a path to a local directory")
            end
        end

        # Our build products will go into ./products
        out_path = joinpath(dir, "products")
        try mkpath(out_path) catch; end

        for platform in platforms
            target = triplet(platform)

            # We build in a platform-specific directory
            build_path = joinpath(pwd(), "build", target)
            try mkpath(build_path) catch; end

            cd(build_path) do
                src_paths, src_hashes = collect(zip(sources...))

                # Convert from tuples to arrays, if need be
                src_paths = collect(src_paths)
                src_hashes = collect(src_hashes)
                prefix, ur = setup_workspace(
                    build_path,
                    src_paths,
                    src_hashes,
                    dependencies,
                    platform;
                    verbose=verbose,
                    downloads_dir=downloads_dir
                )

                # Don't keep the downloads directory around
                rm(joinpath(prefix, "downloads"); force=true, recursive=true)

                # Collect dependency manifests so that our auditing doesn't touch these files that
                # were installed by dependencies
                manifest_dir = joinpath(prefix, "manifests")
                dep_manifests = if isdir(manifest_dir)
                   [joinpath(prefix, "manifests", f) for f in readdir(manifest_dir)]
                else
                    String[]
                end

                dep = Dependency(src_name, products(prefix), script, platform, prefix)
                build(ur, dep; verbose=verbose, autofix=true, ignore_manifests=dep_manifests, debug=debug)

                # Remove the files of any dependencies
                for dependency in dependencies
                    dep_script = script_for_dep(dependency, prefix.path)[1]
                    m = Module(:__anon__)
                    Core.eval(m, quote
                        using BinaryProvider
                        # Override BinaryProvider functionality so that it doesn't actually install anything
                        platform_key() = $platform
                        function write_deps_file(args...; kwargs...); end
                        function install(args...; kwargs...); end

                        # Include build.jl file to extract download_info
                        ARGS = [$(prefix.path)]
                        include_string($(m), $(dep_script))

                        # Grab the information we need in order to extract a manifest, then uninstall it
                        url, hash = download_info[platform_key()]
                        manifest_path = BinaryProvider.manifest_from_url(url; prefix=prefix)
                        BinaryProvider.uninstall(manifest_path; verbose=$verbose)
                    end)
                end

                # Once we're built up, go ahead and package this prefix out
                tarball_path, tarball_hash = package(
                    prefix,
                    joinpath(out_path, src_name),
                    src_version;
                    platform=platform,
                    verbose=verbose,
                    force=true,
               )
                product_hashes[target] = (basename(tarball_path), tarball_hash)

                # Destroy the workspace
                rm(dirname(prefix.path); recursive=true)
            end

            # If the whole build_path is empty, then remove it too.  If it's not, it's probably
            # because some other build is doing something simultaneously with this target, and we
            # don't want to mess with their stuff.
            if isempty(readdir(build_path))
                rm(build_path; recursive=true)
            end

            # Clean up this particular shard, so as not to run out of loopback devices
            unmount_shard(shards_dir(triplet(platform)))
        end
    end

    # At the end of all things, unmount all our shards so as to play nice with others
    unmount_all_shards()

    if (haskey(ENV, "TRAVIS") || haskey(ENV, "CI")) && !verbose
        run_travis_busytask = false
        wait(travis_busytask)
        println()
    end

    # Return our product hashes
    return product_hashes
end

function print_buildjl(io::IO, products::Vector, product_hashes::Dict,
                       bin_path::AbstractString)
    print(io, """
    using BinaryProvider # requires BinaryProvider 0.3.0 or later

    # Parse some basic command-line arguments
    const verbose = "--verbose" in ARGS
    const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))
    """)

    # Print out products
    print(io, "products = [\n")
    for prod in products
        print(io, "    $(repr(prod)),\n")
    end
    print(io, "]\n\n")

    # Print binary locations/tarball hashes
    print(io, """
    # Download binaries from hosted location
    bin_prefix = "$bin_path"

    # Listing of files generated by BinaryBuilder:
    """)

    println(io, "download_info = Dict(")
    for platform in sort(collect(keys(product_hashes)))
        fname, hash = product_hashes[platform]
        pkey = platform_key(platform)
        println(io, "    $(pkey) => (\"\$bin_prefix/$(fname)\", \"$(hash)\"),")
    end
    println(io, ")\n")

    print(io, """
    # Install unsatisfied or updated dependencies:
    unsatisfied = any(!satisfied(p; verbose=verbose) for p in products)
    if haskey(download_info, platform_key())
        url, tarball_hash = download_info[platform_key()]
        if unsatisfied || !isinstalled(url, tarball_hash; prefix=prefix)
            # Download and install binaries
            install(url, tarball_hash; prefix=prefix, force=true, verbose=verbose)
        end
    elseif unsatisfied
        # If we don't have a BinaryProvider-compatible .tar.gz to download, complain.
        # Alternatively, you could attempt to install from a separate provider,
        # build from source or something even more ambitious here.
        error("Your platform \$(triplet(platform_key())) is not supported by this package!")
    end

    # Write out a deps.jl file that will contain mappings for our products
    write_deps_file(joinpath(@__DIR__, "deps.jl"), products, verbose=verbose)
    """)
end

function print_buildjl(build_dir::AbstractString, src_name::AbstractString,
                       src_version::VersionNumber, products::Vector,
                       product_hashes::Dict, bin_path::AbstractString)
    mkpath(joinpath(build_dir, "products"))
    open(joinpath(build_dir, "products", "build_$(src_name).v$(src_version).jl"), "w") do io
        print_buildjl(io, products, product_hashes, bin_path)
    end
end

"""
If you have a sharded build on Github, it would be nice if we could get an auto-generated
`build.jl` just like if we build serially.  This function eases the pain by reconstructing
it from a releases page.
"""
function product_hashes_from_github_release(repo_name::AbstractString, tag_name::AbstractString;
                                            product_filter::AbstractString = "",
                                            verbose::Bool = false)
    # Get list of files within this release
    release = gh_get_json(DEFAULT_API, "/repos/$(repo_name)/releases/tags/$(tag_name)", auth=github_auth())

    # Try to extract the platform key from each, use that to find all tarballs
    function can_extract_platform(filename)
        # Short-circuit build.jl because that's quite often there.  :P
        if startswith(filename, "build") && endswith(filename, ".jl")
            return false
        end

        unknown_platform = typeof(extract_platform_key(filename)) <: UnknownPlatform
        if unknown_platform && verbose
            Compat.@info("Ignoring file $(filename); can't extract its platform key")
        end
        return !unknown_platform
    end
    assets = [a for a in release["assets"] if can_extract_platform(a["name"])]
    assets = [a for a in assets if occursin(product_filter, a["name"])]

    # Download each tarball, hash it, and reconstruct product_hashes.
    product_hashes = Dict()
    mktempdir() do d
        for asset in assets
            # For each asset (tarball), download it
            filepath = joinpath(d, asset["name"])
            url = asset["browser_download_url"]
            BinaryProvider.download(url, filepath; verbose=verbose)

            # Hash it
            hash = open(filepath) do file
                return bytes2hex(sha256(file))
            end

            # Then fit it into our product_hashes
            file_triplet = triplet(extract_platform_key(asset["name"]))
            product_hashes[file_triplet] = (asset["name"], hash)

            if verbose
                Compat.@info("Calculated $hash for $(asset["name"])")
            end
        end
    end

    return product_hashes
end

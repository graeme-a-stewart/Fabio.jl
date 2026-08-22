"""
A command-line converter, after FabIO's `fabio-convert`.

FabIO ships five applications. This is the general one; the others are either domain-specific
(`eiger2cbf`, `eiger2crysalis`, `densify_Bragg`) or a GUI (`fabio_viewer`), and none belongs in
a library.

    julia -e 'using Fabio; exit(Fabio.main())' -- --output-format edf *.cbf

The options and the exit codes follow `fabio-convert`, so a script written against it behaves
the same here: 0 on success, 1 if a conversion failed, 2 if the arguments were wrong.

Argument parsing is done by hand rather than with a package. It is a hundred lines against a
dependency the library itself would not otherwise need, in a package whose whole design is to
stay installable in seconds.
"""

const CLI_USAGE = """
usage: fabio-convert [options] IMAGE...

Convert 2D detector images between formats.

positional arguments:
  IMAGE                    input image files

main arguments:
  -l, --list               show the list of available formats and exit
  -o, --output OUT         output file, or directory when converting several
  -F, --output-format FMT  output format, by name (see --list)

optional behaviour arguments:
  -f, --force              overwrite an existing destination
  -n, --no-clobber         never overwrite an existing destination
  -u, --update             convert only when the source is newer than the destination
      --dry-run            do everything except write anything

  -v, --verbose            report each conversion
  -V, --version            show the version and exit
  -h, --help               show this message and exit

exit codes: 0 success, 1 a conversion failed, 2 bad arguments.
"""

"""One parsed command line."""
struct CLIOptions
    images::Vector{String}
    output::Union{Nothing,String}
    format::Union{Nothing,String}
    list::Bool
    force::Bool
    noclobber::Bool
    update::Bool
    dryrun::Bool
    verbose::Bool
    version::Bool
    help::Bool
end

"""
Parse the command line, or throw `ArgumentError` describing what was wrong with it.

FabIO's `-i/--interactive` and `--remove-destination` are not implemented: prompting has no
place in something meant for pipelines, and `--force` already covers replacing a destination.
"""
function _parsecli(args)
    images = String[]
    output = nothing
    format = nothing
    list = force = noclobber = update = dryrun = verbose = version = help = false

    i = firstindex(args)
    while i <= lastindex(args)
        a = String(args[i])
        if a == "--"
            append!(images, String.(args[(i+1):end]))
            break
        elseif a in ("-h", "--help")
            help = true
        elseif a in ("-V", "--version")
            version = true
        elseif a in ("-v", "--verbose")
            verbose = true
        elseif a in ("-l", "--list")
            list = true
        elseif a in ("-f", "--force")
            force = true
        elseif a in ("-n", "--no-clobber")
            noclobber = true
        elseif a in ("-u", "--update")
            update = true
        elseif a == "--dry-run"
            dryrun = true
        elseif a in ("-o", "--output")
            i += 1
            i <= lastindex(args) || throw(ArgumentError("$a needs a value"))
            output = String(args[i])
        elseif a in ("-F", "--output-format")
            i += 1
            i <= lastindex(args) || throw(ArgumentError("$a needs a value"))
            format = String(args[i])
        elseif startswith(a, "--output=")
            output = a[length("--output=")+1:end]
        elseif startswith(a, "--output-format=")
            format = a[length("--output-format=")+1:end]
        elseif startswith(a, "-") && length(a) > 1
            throw(ArgumentError("unrecognised option $a"))
        else
            push!(images, a)
        end
        i += 1
    end

    return CLIOptions(
        images, output, format, list, force, noclobber, update, dryrun, verbose, version,
        help,
    )
end

"""Print the registry as a table, which is what `--list` is for."""
function _printformats(io::IO)
    println(io, "Formats this build can read, and which of them it can write:")
    println(io)
    println(io, "  ", rpad("name", 12), rpad("mode", 7), rpad("extensions", 34), "description")
    for e in sort(formats(); by = x -> String(x.name))
        exts = isempty(e.extensions) ? "—" : join("." .* e.extensions, " ")
        length(exts) > 32 && (exts = exts[1:31] * "…")
        println(
            io,
            "  ",
            rpad(String(e.name), 12),
            rpad(e.writer ? "rw" : "r", 7),
            rpad(exts, 34),
            e.description,
        )
    end
    println(io)
    println(io, "Formats needing an optional package say so when opened; HDF5 needs `using HDF5`.")
    return nothing
end

"""Work out where one converted file should go."""
function _destination(src::AbstractString, entry::FormatEntry, output::Union{Nothing,String}, many::Bool)
    ext = isempty(entry.extensions) ? String(entry.name) : first(entry.extensions)
    stem = first(splitext(first(stripcompression(String(src)))))
    if output === nothing
        return stem * "." * ext
    elseif isdir(output) || many || endswith(output, Base.Filesystem.path_separator)
        # An existing directory, or several inputs that must go somewhere, means a directory.
        return joinpath(output, basename(stem) * "." * ext)
    else
        return String(output)
    end
end

"""
    main(args = ARGS) -> Int

Run the converter. Returns an exit code rather than calling `exit`, so it is testable and
usable from other Julia code; a shell entry point wraps it in `exit(...)`.
"""
function main(args = ARGS; stdout::IO = Base.stdout, stderr::IO = Base.stderr)
    try
        return _main(args, stdout, stderr)
    catch err
        # `fabio-convert --list | head` closes the pipe early. That is an ordinary way to use
        # a command-line tool, not a failure, and it should not print a Julia stack trace.
        _isbrokenpipe(err) && return 0
        rethrow()
    end
end

"""Whether an error is the far end of a pipe having closed."""
_isbrokenpipe(err) = err isa Base.IOError && err.code == Base.UV_EPIPE
_isbrokenpipe(err::CompositeException) = any(_isbrokenpipe, err.exceptions)

function _main(args, stdout::IO, stderr::IO)
    local opts::CLIOptions
    try
        opts = _parsecli(args)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "fabio-convert: ", err.msg)
        println(stderr, CLI_USAGE)
        return 2
    end

    opts.help && (print(stdout, CLI_USAGE); return 0)
    opts.version && (println(stdout, "Fabio.jl ", something(pkgversion(@__MODULE__), "unknown")); return 0)
    opts.list && (_printformats(stdout); return 0)

    if isempty(opts.images)
        println(stderr, "fabio-convert: no input files")
        println(stderr, CLI_USAGE)
        return 2
    end
    if opts.format === nothing
        println(stderr, "fabio-convert: an output format is required (-F/--output-format)")
        println(stderr, "Run with --list to see the available formats.")
        return 2
    end

    entry = findformat(Symbol(lowercase(opts.format)))
    if entry === nothing
        println(stderr, "fabio-convert: unknown output format ", repr(opts.format))
        println(stderr, "Run with --list to see the available formats.")
        return 2
    end
    if !canwrite(entry.format)
        println(
            stderr,
            "fabio-convert: ",
            opts.format,
            " can be read but not written. Writable formats: ",
            join(string.(writableformats()), ", "),
        )
        return 2
    end

    many = length(opts.images) > 1
    failures = 0
    for src in opts.images
        dst = _destination(src, entry, opts.output, many)
        try
            exists = isfile(dst)
            if exists && opts.noclobber
                opts.verbose && println(stdout, "skip  ", src, " -> ", dst, " (exists)")
                continue
            elseif exists && opts.update && stat(dst).mtime >= stat(src).mtime
                opts.verbose && println(stdout, "skip  ", src, " -> ", dst, " (up to date)")
                continue
            end
            # A dry run reports and stops, ahead of the clobber check: "everything except
            # modifying the file system" should not fail merely because a file is in the way.
            if opts.dryrun
                note = (exists && !opts.force) ? "  (destination exists)" : ""
                println(stdout, "would convert  ", src, " -> ", dst, note)
                continue
            end
            if exists && !opts.force
                println(stderr, "fabio-convert: ", dst, " exists; use --force or --no-clobber")
                failures += 1
                continue
            end
            dstdir = dirname(dst)
            isempty(dstdir) || isdir(dstdir) || mkpath(dstdir)
            openimage(src) do file
                frames = [convertimage(file[i], entry.format) for i = 1:length(file)]
                # The format is named outright rather than left to the destination's
                # extension: `-o out` with no extension is a perfectly good request, and the
                # format is already known for certain.
                writeimage(dst, frames; format = entry.format)
            end
            opts.verbose && println(stdout, "convert  ", src, " -> ", dst)
        catch err
            println(stderr, "fabio-convert: ", src, ": ", sprint(showerror, err))
            failures += 1
        end
    end

    return failures == 0 ? 0 : 1
end

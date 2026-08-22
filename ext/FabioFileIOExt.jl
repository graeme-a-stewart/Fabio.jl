"""
    FabioFileIOExt

[FileIO.jl](https://github.com/JuliaIO/FileIO.jl) registration, so that `load("image.edf")`
and `save("out.edf", frame)` work wherever FileIO is the common currency.

Loaded automatically when the user runs `using FileIO`.

# What gets registered, and what does not

The formats are generated from `Fabio.formats()` rather than listed here, so the two cannot
drift apart — the same argument the README makes for generating the format table from the
registry instead of maintaining it in prose.

Formats FileIO already knows are skipped rather than overridden: `.tif`, `.npy`, `.h5` and the
netpbm family are registered to other packages, and a user loading one of those through
FileIO has asked for the ecosystem's answer, not this package's. They remain reachable here
through `Fabio.readimage`. Anything already claimed under the same name is skipped for the
same reason, and skipping is silent: it is the correct outcome, not a problem.

# Detection

FileIO picks a format from magic bytes and extension, and then this extension ignores that
choice and lets [`Fabio.readimage`](@ref) detect the format itself. That is deliberate. Fabio's
detection is two-stage — magic ordered by specificity, then `refine` — and knows things FileIO's
flat table cannot express, such as three different detector formats sharing `.img`. Routing
every load through it means a file cannot be mis-read because FileIO guessed a sibling format.
"""
module FabioFileIOExt

using FileIO
using Fabio

"""Extensions and format names FileIO already serves through other packages."""
const RESERVED_EXTENSIONS =
    Set([".tif", ".tiff", ".npy", ".h5", ".hdf5", ".pnm", ".pgm", ".pbm"])

"""
    fileio_load(f) -> ImageFrame

FileIO's load hook. Returns an [`Fabio.ImageFrame`](@ref), which is an `AbstractArray` carrying
its header, so it drops straight into anything expecting an array.
"""
Fabio.fileio_load(f::File) = Fabio.readimage(FileIO.filename(f))
Fabio.fileio_load(f::File, ::Type{T}) where {T} = Fabio.readimage(FileIO.filename(f), T)

"""
    fileio_save(f, data)

FileIO's save hook, over [`Fabio.writeimage`](@ref).
"""
Fabio.fileio_save(f::File, data; kwargs...) =
    Fabio.writeimage(FileIO.filename(f), data; kwargs...)

"""The FileIO symbol for one of this package's formats."""
_fileiosym(name::Symbol) = Symbol("FABIO_", uppercase(String(name)))

"""
Register every Fabio format FileIO does not already serve.

Magic patterns are passed through only when they sit at byte zero, which is all FileIO's
registry can express; a format whose signature is elsewhere — MRC stamps `MAP ` at byte 208 —
is registered on its extensions alone, and Fabio's own detection sorts it out on load.
"""
function __init__()
    uuid = Base.PkgId(Fabio).uuid
    for entry in Fabio.formats()
        entry.reader || continue
        sym = _fileiosym(entry.name)
        haskey(FileIO.sym2info, sym) && continue

        exts = [".$e" for e in entry.extensions if !(".$e" in RESERVED_EXTENSIONS)]
        isempty(exts) && continue

        magics = [m.pattern for m in entry.magics if m.offset == 0 && !isempty(m.pattern)]
        magic = isempty(magics) ? UInt8[] : Vector{UInt8}[magics...]
        try
            FileIO.add_format(sym, magic, exts, [:Fabio => uuid])
        catch err
            # Registration failing is not worth breaking a `using FileIO` over, but it is
            # worth saying: silently swallowing it would leave the format quietly absent.
            @warn "Fabio could not register this format with FileIO" format = entry.name exception = err
        end
    end
    return nothing
end

end # module

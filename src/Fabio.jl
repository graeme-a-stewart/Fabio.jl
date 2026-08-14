"""
    Fabio

Reading of 2D detector images and their metadata, after the Python
[FabIO](https://github.com/silx-kit/fabio) library: give it a filename and it works out the
format, handles any compression, and hands back the pixels as a Julia array of the type
actually stored in the file, alongside the header.

```julia
using Fabio, Statistics

frame = Fabio.readimage("image.edf")
mean(frame)                                    # an ImageFrame is an AbstractArray
getheader(header(frame), "ESRFCurrent", Float64)

Fabio.openimage("series.edf") do file          # multi-frame files are AbstractVectors
    for f in file
        println(f.fileindex, ": ", maximum(f))
    end
end
```

# Axis order

`size(frame) == (fast, slow)` — the fast-varying detector axis comes first, the reverse of
numpy's `.shape` as reported by FabIO. This is what lets stored bytes map onto Julia's
column-major memory with no permutation, which in turn makes memory-mapped, zero-copy frames
possible. [`rowmajor`](@ref) and [`imageview`](@ref) give free views in the other conventions.

# Naming

FabIO's `fabio.open` is [`openimage`](@ref) here, and `fabio.open(...).data` is
[`readimage`](@ref). Adding methods to `Base.open(::AbstractString)` would be type piracy, so
the path-based entry points get distinct names; everything that dispatches on this package's
own types (`close`, `length`, `getindex`, iteration) extends `Base` as usual.

# Extending

See [`scan`](@ref) for the tier-1 extension point (parse a header, return a
[`BinaryLayout`](@ref); the core does the rest), [`readframe`](@ref) for tier 2, and
[`register!`](@ref) for wiring a format in — including from another package.
"""
module Fabio

using OrderedCollections: OrderedDict
using CodecZlib: GzipDecompressor, ZlibDecompressor, ZlibCompressor
using TranscodingStreams: transcode
import Mmap

export ImageFrame,
    ImageFile,
    Header,
    ImageFormat,
    getheader,
    header,
    data,
    rowmajor,
    imageview,
    pixeltype,
    openimage,
    readimage,
    readheader,
    readheaders

include("types.jl")
include("header.jl")
include("frame.jl")
include("source.jl")
include("codecs.jl")
include("agi.jl")
include("blob.jl")
include("registry.jl")
include("detect.jl")
include("file.jl")
include("api.jl")

include("formats/edf.jl")
include("formats/esperanto.jl")
include("formats/npy.jl")

export EDF, Esperanto, NPY

"""
    registerdefaults!()

Register the formats built into this package. Called from `__init__`, and safe to call again.

Ordering here does not matter: [`register!`](@ref) sorts the registry by priority and then by
magic-pattern length, so the most specific signature always wins regardless of when it was
added. FabIO, by contrast, relies on the declaration order of its magic table.
"""
function registerdefaults!()
    register!(
        Esperanto();
        name = :esperanto,
        description = "CrysAlis Pro Esperanto",
        extensions = ["esperanto", "esper"],
        magic = [Magic("ESPERANTO FORMAT")],
        writer = false,
    )
    register!(
        NPY();
        name = :npy,
        description = "NumPy array container",
        extensions = ["npy"],
        magic = [Magic(NPY_MAGIC)],
        writer = false,
    )
    register!(
        EDF();
        name = :edf,
        description = "ESRF Data Format",
        extensions = ["edf", "cor"],
        magic = [
            Magic("{\r\nEDF"),
            Magic("\n{\r\nEDF"),
            Magic("{\r\n"),
            Magic("{\n"),
            Magic("\n{\n"),
            Magic("{"),
        ],
        priority = -1,   # EDF's bare "{" is the least specific signature in the table
        writer = false,
    )
    return REGISTRY
end

function __init__()
    registerdefaults!()
    return nothing
end

end # module

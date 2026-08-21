"""
    scan(fmt, src) -> (fileheader::Header, specs::Vector{FrameSpec})

**The tier-1 extension point.** Parse metadata only — never pixel data — and describe each
frame with a [`FrameSpec`](@ref). A format that implements just this method gets opening,
decompression, memory mapping, decoding, byte-order correction, orientation, frame iteration
and error reporting from the core.

`fileheader` carries metadata that applies to the whole file (EDF's general block, a NeXus
entry's attributes); it is merged underneath each frame's own header.
"""
function scan end

"""
    openstate(fmt, src, fileheader, specs) -> state

Optional. Per-file scratch a format wants to keep (an HDF5 handle, a decoded IFD table). It is
stored in [`ImageFile`](@ref)'s type-parameterised `state` field, so a format needs no
subclassing to carry its own bookkeeping. Default: `nothing`.
"""
openstate(::ImageFormat, ::AbstractSource, ::Header, ::Vector{FrameSpec}) = nothing

"""
    closestate(fmt, state)

Optional counterpart to [`openstate`](@ref), called by `close`. Default: no-op.
"""
closestate(::ImageFormat, state) = nothing

"""
    needs_random_access(fmt) -> Bool

Whether the format must address its source out of order. `false` permits a compressed file to
be streamed rather than decompressed into memory in one go.

This single trait replaces FabIO's `_need_a_seek_to_read` / `_need_a_real_file` pair and the
temporary-file dance in `_compressed_stream`. Default: `true` (always safe).
"""
needs_random_access(::ImageFormat) = true

"""
    coerce(fmt, A) -> AbstractArray

Adapt an array to what `fmt` can physically store, in element type and — where the format
insists — shape. Called on the way into `writeimage` and `convert`.

The FabIO documentation is explicit that conversion "tak[es] care of the numerical specifics:
for example float arrays are converted to integer arrays if the output format only accepts
integers", and Esperanto goes further, demanding a square image whose side is a multiple of
four between 256 and 4096. Formats express those constraints here, once, so that a direct
write and a format conversion cannot disagree. Default: identity.
"""
coerce(::ImageFormat, A::AbstractArray) = A

"""
    ImageFile{F,S,X,T,N} <: AbstractVector{ImageFrame}

An open image file: the format, the byte source, the frames discovered by [`scan`](@ref), and
any format-private `state`.

`ImageFile` is an `AbstractVector` of frames, so `length(file)`, `file[i]`, `file[2:5]` and
`for frame in file` all work. Frame indices are **1-based**, like everything else in Julia
(FabIO counts frames from 0).

# Type stability

The pixel type cannot be known until the header has been read, so `openimage` performs one
dynamic dispatch and bakes the result into `T`. Everything downstream of that — every frame
read, every loop over frames — is inferred. `pixeltype(file)` reports it, and it is `Any` for
the rare file whose frames genuinely differ in type.
"""
mutable struct ImageFile{F<:ImageFormat,S<:AbstractSource,X,T,N} <: AbstractVector{ImageFrame}
    format::F
    source::S
    path::Union{Nothing,String}
    fileheader::Header
    frames::Vector{FrameSpec}
    state::X
    truncated::Bool
    mmap::Bool
    closed::Bool
end

Base.size(f::ImageFile) = (length(f.frames),)
Base.IndexStyle(::Type{<:ImageFile}) = IndexLinear()

"""
    pixeltype(file) -> Type

The element type of this file's frames, or `Any` if they differ.
"""
pixeltype(::ImageFile{F,S,X,T}) where {F,S,X,T} = T

"""
    imageformat(file) -> ImageFormat
"""
imageformat(f::ImageFile) = f.format

"""
    fileheader(file) -> Header

Metadata that applies to the whole file rather than to a single frame.
"""
fileheader(f::ImageFile) = f.fileheader

"""
    istruncated(file) -> Bool

True when the file ended before its headers said it would and it was opened with
`strict = false`. FabIO calls this `incomplete_file`; it is common with detectors that are
still writing.
"""
istruncated(f::ImageFile) = f.truncated

function Base.getindex(f::ImageFile{F,S,X,T,N}, i::Int) where {F,S,X,T,N}
    @boundscheck checkbounds(f, i)
    return readframe(f, i)::ImageFrame{<:Any,N}
end

function Base.close(f::ImageFile)
    f.closed && return nothing
    closestate(f.format, f.state)
    close(f.source)
    f.closed = true
    return nothing
end

"""
    readframe(file, i) -> ImageFrame

**The tier-2 extension point.** Formats that decode their own pixels (TIFF, HDF5, JPEG)
override this; everything else inherits the default below, which drives the frame's
[`BinaryLayout`](@ref) through [`readblob`](@ref).
"""
readframe(f::ImageFile, i::Int) = readframe_layout(f, i)

"""
    readframe_layout(file, i) -> ImageFrame

The tier-1 frame reader: drive the frame's [`BinaryLayout`](@ref) through [`readblob`](@ref).

This is the default [`readframe`](@ref). It is public so that a tier-2 format can fall back to
it for the frames it *can* describe as a layout, and take over only for the ones it cannot —
TIFF does exactly that, handling contiguous images here and gathering multi-strip ones itself.
"""
function readframe_layout(f::ImageFile, i::Int)
    spec = f.frames[i]
    layout = spec.layout
    layout === nothing && throw(
        UnsupportedFormatError(
            "$(nameof(typeof(f.format))) frames carry no binary layout and the format " *
            "does not implement `readframe`",
        ),
    )
    A = nothing
    if f.mmap
        A = mmapblob(f.source, layout)
    end
    if A === nothing
        A = readblob(f.source, layout)
    end
    return ImageFrame(
        A,
        _frameheader(f, spec),
        fileindex = i,
        seriesindex = i,
        source = f.path,
        format = f.format,
    )
end

function _frameheader(f::ImageFile, spec::FrameSpec)
    isempty(f.fileheader) && return spec.header
    h = copy(f.fileheader)
    merge!(h, spec.header)
    return h
end

"""
    openimage(path; format=nothing, mmap=true, strict=true) -> ImageFile
    openimage(f::Function, path; kwargs...)

Open an image file, reading its metadata but none of its pixels.

FabIO's equivalent is `fabio.open`. The name differs deliberately: adding a method to
`Base.open(::AbstractString)` would be type piracy, and shadowing `open` inside a package that
users call with `using` is worse.

- `format` — skip detection and use this format.
- `mmap` — memory-map uncompressed files, so frames can be returned as zero-copy views.
  Views are only valid while the file is open.
- `strict` — when `false`, a file that ends mid-frame yields the frames that did scan cleanly
  and sets [`istruncated`](@ref) rather than throwing.

The do-block form closes the file for you:

```julia
Fabio.openimage("image.edf") do file
    println(length(file), " frames of ", pixeltype(file))
end
```
"""
function openimage(
    path::AbstractString;
    format::Union{Nothing,ImageFormat} = nothing,
    mmap::Bool = true,
    strict::Bool = true,
)
    src = opensource(path; mmap = mmap)
    try
        return _openimage(src, sourcepath(src), format, mmap, strict)
    catch
        close(src)
        rethrow()
    end
end

function openimage(
    buf::Vector{UInt8};
    format::Union{Nothing,ImageFormat} = nothing,
    strict::Bool = true,
)
    src = opensource(buf)
    try
        return _openimage(src, nothing, format, false, strict)
    catch
        close(src)
        rethrow()
    end
end

function openimage(f::Function, args...; kwargs...)
    file = openimage(args...; kwargs...)
    try
        return f(file)
    finally
        close(file)
    end
end

function _openimage(
    src::AbstractSource,
    path::Union{Nothing,String},
    format::Union{Nothing,ImageFormat},
    mmap::Bool,
    strict::Bool,
)
    fmt = detectformat(src; path = path, format = format)
    truncated = false
    local fh::Header, specs::Vector{FrameSpec}
    if strict
        fh, specs = scan(fmt, src)
    else
        try
            fh, specs = scan(fmt, src)
        catch err
            err isa TruncatedFileError || rethrow()
            fh, specs = something(_partialscan(fmt, src), (Header(), FrameSpec[]))
            truncated = true
        end
    end
    isempty(specs) &&
        strict &&
        throw(CorruptFileError("$(nameof(typeof(fmt))): no frames found in $(something(path, "<buffer>"))"))

    state = openstate(fmt, src, fh, specs)
    T = _commoneltype(specs)
    N = 2
    # The single dynamic dispatch of the whole pipeline: `T` is a runtime value here, and
    # every later operation on the returned object is inferred from it.
    return ImageFile{typeof(fmt),typeof(src),typeof(state),T,N}(
        fmt,
        src,
        path,
        fh,
        specs,
        state,
        truncated,
        mmap,
        false,
    )
end

_partialscan(::ImageFormat, ::AbstractSource) = nothing

function _commoneltype(specs::Vector{FrameSpec})
    isempty(specs) && return Any
    T = eltype(specs[1])
    for s in specs
        eltype(s) === T || return Any
    end
    return T
end

function Base.show(io::IO, ::MIME"text/plain", f::ImageFile)
    n = length(f.frames)
    print(io, "ImageFile{", nameof(typeof(f.format)), "}")
    f.path === nothing || print(io, " ", basename(f.path))
    print(io, ": ", n, " frame", n == 1 ? "" : "s")
    if n > 0 && f.frames[1].layout !== nothing
        print(io, " of ", join(framedims(f.frames[1]), "×"), " ", pixeltype(f))
    end
    f.truncated && print(io, " [TRUNCATED]")
    f.closed && print(io, " [closed]")
end

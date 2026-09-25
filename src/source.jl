"""
    AbstractSource

Where the bytes come from. Formats never open files themselves; they receive a source and
address it by byte offset, so transparent decompression, memory mapping and in-memory streams
are all invisible to them.

The interface is:

    filesize(src)              -> Int
    bytes(src, offset, n)      -> AbstractVector{UInt8}   (0-based offset; zero-copy view)
    israndomaccess(src)        -> Bool

Offsets are **0-based** throughout the source layer, matching the file formats' own header
fields; the byte vectors handed back are ordinary 1-based Julia arrays.
"""
abstract type AbstractSource end

"""
    MmapSource

A plain file mapped into memory. Reads are zero-copy views, and because the mapping is
read-only and immutable it is safe to read from several threads at once.
"""
struct MmapSource <: AbstractSource
    buf::Vector{UInt8}
    path::String
    io::IOStream
    fragment::Union{Nothing,String}
end

"""
    BufferSource

Bytes already in memory: a decompressed file, or an in-memory stream.
"""
struct BufferSource <: AbstractSource
    buf::Vector{UInt8}
    path::Union{Nothing,String}
    fragment::Union{Nothing,String}
end

const _RASource = Union{MmapSource,BufferSource}

Base.filesize(src::_RASource) = length(src.buf)
israndomaccess(::_RASource) = true
sourcepath(src::MmapSource) = src.path
sourcepath(src::BufferSource) = src.path

"""
    sourcefragment(src) -> Union{Nothing,String}

The part of the path after a `::` separator, or `nothing`.

FabIO addresses a dataset inside an HDF5 container as `filename::/group/dataset`, and makes
the separator mandatory for its flat HDF5 reader. Carrying the fragment on the source keeps
[`scan`](@ref)'s signature unchanged: a format that needs an in-file address reads it from
here, and every other format never sees it.
"""
sourcefragment(src::_RASource) = src.fragment

"""
    bytes(src, offset, n) -> AbstractVector{UInt8}

`n` bytes starting at 0-based byte `offset`. Zero-copy where the source allows it.
Throws [`TruncatedFileError`](@ref) if the range runs past the end of the data.
"""
function bytes(src::_RASource, offset::Integer, n::Integer)
    lo = Int(offset) + 1
    hi = lo + Int(n) - 1
    (lo < 1 || hi > length(src.buf)) && throw(
        TruncatedFileError(
            "requested bytes $(offset)…$(offset + n - 1) but the file holds $(length(src.buf))",
        ),
    )
    return view(src.buf, lo:hi)
end

"""
    bytesfrom(src, offset) -> AbstractVector{UInt8}

Everything from 0-based `offset` to the end of the data.
"""
bytesfrom(src::_RASource, offset::Integer) =
    bytes(src, offset, length(src.buf) - Int(offset))

Base.close(src::MmapSource) = close(src.io)
Base.close(::BufferSource) = nothing

# --------------------------------------------------------------------- compression

"""Recognised whole-file compression suffixes."""
const COMPRESSION_SUFFIXES = (".gz", ".bz2", ".xz", ".zst")

"""
    stripcompression(path) -> (stem, suffix)

Split a trailing compression suffix off a path. `suffix` is `""` when there is none.
Used for extension-based format detection so that `image.edf.gz` still resolves to EDF.
"""
function stripcompression(path::AbstractString)
    for sfx in COMPRESSION_SUFFIXES
        endswith(lowercase(path), sfx) && return (path[1:end-length(sfx)], sfx)
    end
    return (String(path), "")
end

"""
    splitfragment(path) -> (file, fragment)

Split a `filename::/group/dataset` container reference. `fragment` is `nothing` when there is
no `::` separator. Two colons are required, so a Windows drive letter is never mistaken for
one.
"""
function splitfragment(path::AbstractString)
    i = findfirst("::", String(path))
    i === nothing && return (String(path), nothing)
    return (String(path[1:first(i)-1]), String(path[last(i)+1:end]))
end

"""
    compressioncodec(::Val{suffix}) -> Union{Nothing,Tuple{Type,Type}}

The `(Decompressor, Compressor)` pair of TranscodingStreams codecs for a whole-file
compression suffix, as a `Symbol` without the dot (`Val(:bz2)`), or `nothing` if the codec is
not available.

gzip is built in. bzip2, xz and zstd arrive with extensions that add a method here when the
user loads CodecBzip2, CodecXz or CodecZstd, so the core carries none of those binary
dependencies.
"""
compressioncodec(::Val) = nothing
compressioncodec(::Val{:gz}) = (GzipDecompressor, GzipCompressor)

"""The codec package that provides each optional compression suffix."""
const COMPRESSION_PACKAGES = Dict(".bz2" => "CodecBzip2", ".xz" => "CodecXz", ".zst" => "CodecZstd")

function _compressioncodec(suffix::AbstractString)
    codec = compressioncodec(Val(Symbol(lstrip(suffix, '.'))))
    codec === nothing || return codec
    pkg = get(COMPRESSION_PACKAGES, suffix, nothing)
    pkg === nothing && throw(ArgumentError("unknown compression suffix $(repr(suffix))"))
    throw(
        UnsupportedFormatError(
            "$(lstrip(suffix, '.'))-compressed files need $pkg; run `using $pkg`",
        ),
    )
end

"""
    decompress(suffix, raw) -> Vector{UInt8}

Decompress a whole file held in `raw`. `suffix` is one of `COMPRESSION_SUFFIXES`, or
`""` for no compression. `.gz` is supported by the core; the remaining algorithms arrive with
their optional packages, see [`compressioncodec`](@ref).
"""
function decompress(suffix::AbstractString, raw::Vector{UInt8})
    isempty(suffix) && return raw
    D, _ = _compressioncodec(suffix)
    return transcode(D, raw)
end

"""
    compress(suffix, raw) -> Vector{UInt8}

The inverse of [`decompress`](@ref), used by `writeimage` for a compressed destination.
"""
function compress(suffix::AbstractString, raw::Vector{UInt8})
    isempty(suffix) && return raw
    _, C = _compressioncodec(suffix)
    return transcode(C, raw)
end

"""
    sniffcompression(head) -> String

The compression suffix implied by a file's first bytes, or `""`.

Extensions lie: FabIO's own test archive serves a bzip2 file as `100nmfilmonglass_1_1.img`.
These signatures are what the compressors themselves write, so a match is decisive:

| | signature |
|---|---|
| gzip  | `1f 8b 08` (deflate is the only method in use) |
| bzip2 | `BZh`, a block size digit `1`–`9`, then the block magic `1AY&SY` or, for an empty stream, the end-of-stream magic |
| xz    | `fd 37 7a 58 5a 00` |
| zstd  | `28 b5 2f fd` |

bzip2 is checked to ten bytes rather than three because `BZh` alone is printable ASCII that
a text header could plausibly begin with.
"""
function sniffcompression(head::AbstractVector{UInt8})
    n = length(head)
    n >= 3 && head[1] == 0x1f && head[2] == 0x8b && head[3] == 0x08 && return ".gz"
    if n >= 10 && head[1] == UInt8('B') && head[2] == UInt8('Z') && head[3] == UInt8('h') &&
       UInt8('1') <= head[4] <= UInt8('9')
        block = @view head[5:10]
        (block == b"1AY&SY" || block == UInt8[0x17, 0x72, 0x45, 0x38, 0x50, 0x90]) &&
            return ".bz2"
    end
    n >= 6 && @view(head[1:6]) == UInt8[0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00] && return ".xz"
    n >= 4 && @view(head[1:4]) == UInt8[0x28, 0xb5, 0x2f, 0xfd] && return ".zst"
    return ""
end

"""
    opensource(path; mmap=true) -> AbstractSource

Open `path`, transparently decompressing a compressed file.

Compression is recognised by suffix (`.gz`, `.bz2`, `.xz`, `.zst`) and, failing that, by the
file's leading bytes (see [`sniffcompression`](@ref)), so a compressed file under a misleading
name still opens. FabIO relies on the suffix alone.

An uncompressed file becomes an [`MmapSource`](@ref) (zero-copy, thread-safe); a compressed
one is decompressed once into a [`BufferSource`](@ref). This is where FabIO's
`_need_a_seek_to_read` / `_need_a_real_file` special-casing lives, minus the temporary files:
every source in this version is randomly addressable.
"""
function opensource(path::AbstractString; mmap::Bool = true)
    file, fragment = splitfragment(path)
    isfile(file) || throw(ArgumentError("no such file: $file"))
    _, sfx = stripcompression(file)
    isempty(sfx) || return BufferSource(decompress(sfx, Base.read(file)), file, fragment)
    head = Base.open(io -> Base.read(io, 10), file, "r")
    sfx = sniffcompression(head)
    isempty(sfx) || return BufferSource(decompress(sfx, Base.read(file)), file, fragment)
    if mmap
        io = Base.open(file, "r")
        buf = Mmap.mmap(io, Vector{UInt8}, filesize(io))
        return MmapSource(buf, file, io, fragment)
    end
    return BufferSource(Base.read(file), file, fragment)
end

"""
    opensource(bytes::Vector{UInt8}) -> BufferSource

Wrap an in-memory buffer, e.g. bytes received over a network.
"""
opensource(buf::Vector{UInt8}) = BufferSource(buf, nothing, nothing)

# --------------------------------------------------------------- byte scanning

"""Byte at 0-based `offset`. No bounds check: callers have already sized the read."""
@inline _byteat(src::AbstractSource, offset::Integer) = @inbounds src.buf[Int(offset)+1]

"""Find `needle` in `src` at or after 0-based `from`; return the 0-based offset or `nothing`."""
function _findbytes(src::AbstractSource, needle::AbstractVector{UInt8}, from::Integer = 0)
    n = filesize(src)
    m = length(needle)
    m == 0 && return Int(from)
    buf = src.buf
    first = needle[1]
    i = Int(from) + 1
    stop = n - m + 1
    @inbounds while i <= stop
        if buf[i] == first
            ok = true
            for j = 2:m
                if buf[i+j-1] != needle[j]
                    ok = false
                    break
                end
            end
            ok && return i - 1
        end
        i += 1
    end
    return nothing
end

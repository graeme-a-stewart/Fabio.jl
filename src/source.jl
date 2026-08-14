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
end

"""
    BufferSource

Bytes already in memory: a decompressed file, or an in-memory stream.
"""
struct BufferSource <: AbstractSource
    buf::Vector{UInt8}
    path::Union{Nothing,String}
end

const _RASource = Union{MmapSource,BufferSource}

Base.filesize(src::_RASource) = length(src.buf)
israndomaccess(::_RASource) = true
sourcepath(src::MmapSource) = src.path
sourcepath(src::BufferSource) = src.path

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
    decompress(suffix, raw) -> Vector{UInt8}

Decompress a whole file held in `raw`. `.gz` is supported by the core; the remaining
algorithms arrive with their optional packages.
"""
function decompress(suffix::AbstractString, raw::Vector{UInt8})
    if suffix == ".gz"
        return transcode(GzipDecompressor, raw)
    elseif suffix == ".bz2"
        throw(
            UnsupportedFormatError(
                "bzip2-compressed files need CodecBzip2; run `using CodecBzip2` " *
                "(support arrives with the Fabio bzip2 extension)",
            ),
        )
    elseif suffix == ".xz"
        throw(UnsupportedFormatError("xz-compressed files need CodecXz; run `using CodecXz`"))
    elseif suffix == ".zst"
        throw(
            UnsupportedFormatError(
                "zstd-compressed files need CodecZstd; run `using CodecZstd`",
            ),
        )
    end
    return raw
end

"""
    opensource(path; mmap=true) -> AbstractSource

Open `path`, transparently decompressing a recognised compression suffix.

An uncompressed file becomes an [`MmapSource`](@ref) (zero-copy, thread-safe); a compressed
one is decompressed once into a [`BufferSource`](@ref). This is where FabIO's
`_need_a_seek_to_read` / `_need_a_real_file` special-casing lives, minus the temporary files:
every source in this version is randomly addressable.
"""
function opensource(path::AbstractString; mmap::Bool = true)
    isfile(path) || throw(ArgumentError("no such file: $path"))
    _, sfx = stripcompression(path)
    if isempty(sfx)
        if mmap
            io = Base.open(path, "r")
            buf = Mmap.mmap(io, Vector{UInt8}, filesize(io))
            return MmapSource(buf, String(path), io)
        else
            return BufferSource(Base.read(path), String(path))
        end
    end
    return BufferSource(decompress(sfx, Base.read(path)), String(path))
end

"""
    opensource(bytes::Vector{UInt8}) -> BufferSource

Wrap an in-memory buffer, e.g. bytes received over a network.
"""
opensource(buf::Vector{UInt8}) = BufferSource(buf, nothing)

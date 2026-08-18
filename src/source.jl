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
    file, fragment = splitfragment(path)
    isfile(file) || throw(ArgumentError("no such file: $file"))
    _, sfx = stripcompression(file)
    if isempty(sfx)
        if mmap
            io = Base.open(file, "r")
            buf = Mmap.mmap(io, Vector{UInt8}, filesize(io))
            return MmapSource(buf, file, io, fragment)
        else
            return BufferSource(Base.read(file), file, fragment)
        end
    end
    return BufferSource(decompress(sfx, Base.read(file)), file, fragment)
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

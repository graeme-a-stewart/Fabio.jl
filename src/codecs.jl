"""
    AbstractDataCodec

How pixel data is encoded *inside* a file, as distinct from whole-file compression (which the
source layer handles). Codecs are pure functions over byte buffers:

    decode(codec, raw, T, dims) -> Array{T,2}
    encode(codec, A)            -> Vector{UInt8}

Keeping them free of any file or format context makes them independently testable and lets a
format switch encoding by changing one field of its [`BinaryLayout`](@ref).
"""
abstract type AbstractDataCodec end

"""Uncompressed data: `prod(dims)` elements of `T` laid out contiguously."""
struct RawBlob <: AbstractDataCodec end

"""Deflate/zlib-compressed raw data, as used by EDF's `Compression = Zlib`."""
struct ZlibBlob <: AbstractDataCodec end

"""
    decode(codec, raw, ::Type{T}, dims) -> Array{T,2}

Decode `raw` into a `dims`-shaped array of `T`. `dims` is in Julia `(fast, slow)` order.
The result is always in native byte order for multi-byte codecs that imply one; for
[`RawBlob`](@ref) byte order is applied afterwards by the blob layer.
"""
function decode end

# ------------------------------------------------------------------------- raw blobs

function decode(::RawBlob, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    n = prod(dims)
    need = n * sizeof(T)
    length(raw) < need && throw(
        TruncatedFileError("raw blob holds $(length(raw)) bytes, need $need for $dims of $T"),
    )
    out = Array{T}(undef, dims)
    GC.@preserve out raw begin
        unsafe_copyto!(
            Ptr{UInt8}(pointer(out)),
            pointer(raw),
            need,
        )
    end
    return out
end

function encode(::RawBlob, A::AbstractArray{T,2}) where {T}
    out = Vector{UInt8}(undef, length(A) * sizeof(T))
    src = A isa Array ? A : Array(A)
    GC.@preserve out src unsafe_copyto!(pointer(out), Ptr{UInt8}(pointer(src)), length(out))
    return out
end

# --------------------------------------------------------------------- zlib-in-file

function decode(::ZlibBlob, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    inflated = transcode(ZlibDecompressor, Vector{UInt8}(raw))
    return decode(RawBlob(), inflated, T, dims)
end

encode(::ZlibBlob, A::AbstractArray{T,2}) where {T} =
    transcode(ZlibCompressor, encode(RawBlob(), A))

# ------------------------------------------------------------------- little helpers
# Shared by the hand-written codecs. Little-endian scalar loads from a 1-based byte vector.

@inline function _load_u16(raw::AbstractVector{UInt8}, p::Int)
    @inbounds UInt16(raw[p]) | (UInt16(raw[p+1]) << 8)
end

@inline function _load_u32(raw::AbstractVector{UInt8}, p::Int)
    @inbounds UInt32(raw[p]) |
              (UInt32(raw[p+1]) << 8) |
              (UInt32(raw[p+2]) << 16) |
              (UInt32(raw[p+3]) << 24)
end

@inline _load_i16(raw::AbstractVector{UInt8}, p::Int) = reinterpret(Int16, _load_u16(raw, p))
@inline _load_i32(raw::AbstractVector{UInt8}, p::Int) = reinterpret(Int32, _load_u32(raw, p))

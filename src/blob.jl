"""
    BinaryLayout{T,C}(offset, nbytes, dims, byteorder, codec, transform)

A complete description of where one frame's pixels live and how they are encoded. This is the
contract between a format and the core: a tier-1 format parses its header, returns a layout,
and never touches the pixel data itself.

- `offset`  — 0-based byte offset into the (decompressed) source
- `nbytes`  — stored size, which differs from `prod(dims) * sizeof(T)` when compressed
- `dims`    — `(fast, slow)` in Julia order (see [`ImageFrame`](@ref))
- `byteorder` — of the stored values; a no-op when it matches the host
- `codec`   — an [`AbstractDataCodec`](@ref)
- `transform` — an [`Orientation`](@ref) applied after decoding
"""
struct BinaryLayout{T,C<:AbstractDataCodec}
    offset::Int64
    nbytes::Int64
    dims::Dims{2}
    byteorder::ByteOrder
    codec::C
    transform::Orientation
end

function BinaryLayout{T}(
    offset::Integer,
    nbytes::Integer,
    dims::Dims{2};
    byteorder::ByteOrder = LittleEndian(),
    codec::AbstractDataCodec = RawBlob(),
    transform::Orientation = Identity(),
) where {T}
    BinaryLayout{T,typeof(codec)}(
        Int64(offset),
        Int64(nbytes),
        dims,
        byteorder,
        codec,
        transform,
    )
end

Base.eltype(::BinaryLayout{T}) where {T} = T
Base.eltype(::Type{<:BinaryLayout{T}}) where {T} = T

"""
    FrameSpec(header, layout)

What a scan discovers about one frame, before any pixel is read. `layout` is `nothing` for
tier-2 formats, which read their own pixel data via [`readframe`](@ref).
"""
struct FrameSpec{L}
    header::Header
    layout::L
end

Base.eltype(::FrameSpec{<:BinaryLayout{T}}) where {T} = T
Base.eltype(::FrameSpec{Nothing}) = Any

framedims(s::FrameSpec{<:BinaryLayout}) = s.layout.dims

"""
    readblob(src, layout) -> Array{T,2}

Decode one frame: fetch the stored bytes, run the codec, fix byte order, apply the
orientation. Every tier-1 format's pixel path goes through here, so mmap, endianness and
orientation are implemented once.

For an uncompressed, native-endian, unoriented blob backed by an [`MmapSource`](@ref) this
still copies once into an owned `Array`; use [`mmapblob`](@ref) for the zero-copy view.
"""
function readblob(src::AbstractSource, layout::BinaryLayout{T}) where {T}
    raw = bytes(src, layout.offset, layout.nbytes)
    A = decode(layout.codec, raw, T, layout.dims)::Array{T,2}
    _fixbyteorder!(A, layout.byteorder, layout.codec)
    return _orient(A, layout.transform)
end

"""
    mmapblob(src, layout) -> AbstractArray{T,2}

A zero-copy view onto the file for the case where nothing has to be done to the bytes:
uncompressed, native byte order, no reorientation, and a source that is memory mapped.
Returns `nothing` when those conditions do not hold, so callers fall back to [`readblob`](@ref).

The returned array is only valid while the [`ImageFile`](@ref) stays open.
"""
function mmapblob(src::AbstractSource, layout::BinaryLayout{T}) where {T}
    (src isa MmapSource) || return nothing
    (layout.codec isa RawBlob) || return nothing
    isnative(layout.byteorder) || return nothing
    (layout.transform isa Identity) || return nothing
    isbitstype(T) || return nothing
    need = prod(layout.dims) * sizeof(T)
    layout.offset + need > length(src.buf) && return nothing
    # Only safe when the blob starts at a properly aligned byte.
    (layout.offset % sizeof(T) == 0) || return nothing
    raw = bytes(src, layout.offset, need)
    return reshape(reinterpret(T, raw), layout.dims)
end

_fixbyteorder!(A, bo::ByteOrder, ::AbstractDataCodec) = _fixbyteorder!(A, bo)
# Codecs that produce host-order integers by construction need no swap; for those the
# stored element byte order describes the escapes, which they have already handled.
_fixbyteorder!(A, ::ByteOrder, ::AGIBitfield) = A
_fixbyteorder!(A, ::ByteOrder, ::ByteOffset) = A

function _fixbyteorder!(A::Array{T}, bo::ByteOrder) where {T}
    (isnative(bo) || sizeof(T) == 1) && return A
    @inbounds for i in eachindex(A)
        A[i] = bswap(A[i])
    end
    return A
end

_orient(A, ::Identity) = A
_orient(A, ::FlipFast) = reverse(A; dims = 1)
_orient(A, ::FlipSlow) = reverse(A; dims = 2)

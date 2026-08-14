"""
    AGIBitfield(rowstart = UInt32[])

The bit-field codec used by CrysAlis Pro Esperanto files (`spixelformat = "AGI_BITFIELD"`).

# Format

Each detector row is stored as a first pixel followed by differences from the previous pixel;
the row is reconstructed with a cumulative sum. Differences are packed 16 at a time: a length
byte gives two nibbles `(len_b, len_a)`, then `len_a` bytes hold eight `len_a`-bit values and
`len_b` bytes hold eight `len_b`-bit values, each biased by `2^(len-1) - 1`. Values that do not
fit escape to a 16- or 32-bit little-endian integer appended after the packed fields. The
remaining `(row_length - 1) % 16` pixels are written as escaped bytes.

# The row index

The blob ends with a table of `UInt32` offsets, one per row, pointing into the compressed
stream. FabIO reads this table and discards it (`# read data components (row indices are
ignored)`), decoding strictly sequentially. Passing it here turns the codec into a
random-access one: rows are decoded independently and in parallel across threads, and each
row's start offset is validated before it is used. Pass an empty vector to force the
sequential path.
"""
struct AGIBitfield <: AbstractDataCodec
    rowstart::Vector{UInt32}
end
AGIBitfield() = AGIBitfield(UInt32[])

"""Read a value that may be escaped to 2 or 4 bytes. Returns `(value, newposition)`."""
@inline function _agi_read_escaped(raw::AbstractVector{UInt8}, p::Int)
    b = @inbounds raw[p]
    p += 1
    if b == 0xFE
        v = Int32(_load_i16(raw, p))
        p += 2
    elseif b == 0xFF
        v = _load_i32(raw, p)
        p += 4
    else
        v = Int32(b) - Int32(127)
    end
    return v, p
end

"""Load `n` (≤ 8) little-endian bytes into a `UInt64`."""
@inline function _agi_load_le(raw::AbstractVector{UInt8}, p::Int, n::Int)
    w = UInt64(0)
    @inbounds for i = 0:(n-1)
        w |= UInt64(raw[p+i]) << (8 * i)
    end
    return w
end

"""
Unpack the eight `len`-bit values held in `w` into `out[idx:idx+7]`, consuming any escape
bytes that follow at `raw[p]`. Returns the new position.
"""
@inline function _agi_unpack_field!(
    out::AbstractVector{Int32},
    idx::Int,
    w::UInt64,
    len::Int,
    raw::AbstractVector{UInt8},
    p::Int,
)
    mask = (UInt64(1) << len) - UInt64(1)
    bias = Int32((1 << (len - 1)) - 1)
    @inbounds for i = 0:7
        val = (w >> (len * i)) & mask
        if len == 8 && val == 0xFE
            out[idx+i] = Int32(_load_i16(raw, p))
            p += 2
        elseif len == 8 && val == 0xFF
            out[idx+i] = _load_i32(raw, p)
            p += 4
        else
            out[idx+i] = Int32(val) - bias
        end
    end
    return p
end

"""
Decode one row into `out` (which must be exactly one detector row long), starting at `raw[p]`.
Returns the position just past the row, so the caller can decode sequentially.
"""
function _agi_decode_row!(out::AbstractVector{Int32}, raw::AbstractVector{UInt8}, p::Int)
    n = length(out)
    n == 0 && return p

    v, p = _agi_read_escaped(raw, p)
    @inbounds out[1] = v

    nfields, nrest = divrem(n - 1, 16)
    idx = 2
    for _ = 1:nfields
        lb = @inbounds raw[p]
        p += 1
        len_b = Int(lb >> 4)
        len_a = Int(lb & 0x0F)
        # A zero-length field cannot occur in valid data: the encoder's field size is at
        # least 1 bit. FabIO would silently mis-bias such a field; we refuse it instead.
        (len_a < 1 || len_a > 8 || len_b < 1 || len_b > 8) &&
            throw(CorruptFileError("AGI bitfield: invalid field length byte 0x$(string(lb, base=16, pad=2))"))
        wa = _agi_load_le(raw, p, len_a)
        p += len_a
        wb = _agi_load_le(raw, p, len_b)
        p += len_b
        p = _agi_unpack_field!(out, idx, wa, len_a, raw, p)
        idx += 8
        p = _agi_unpack_field!(out, idx, wb, len_b, raw, p)
        idx += 8
    end
    for _ = 1:nrest
        v, p = _agi_read_escaped(raw, p)
        @inbounds out[idx] = v
        idx += 1
    end

    # Differences -> absolute values.
    acc = @inbounds out[1]
    @inbounds for i = 2:n
        acc += out[i]
        out[i] = acc
    end
    return p
end

function decode(
    codec::AGIBitfield,
    raw::AbstractVector{UInt8},
    ::Type{Int32},
    dims::Dims{2},
)
    nfast, nslow = dims          # nfast = row length (lnx), nslow = number of rows (lny)
    length(raw) < 4 && throw(TruncatedFileError("AGI bitfield blob is shorter than its size field"))
    datasize = Int(_load_u32(raw, 1))
    datasize + 4 > length(raw) &&
        throw(TruncatedFileError("AGI bitfield: declared block of $datasize bytes exceeds the $(length(raw)) available"))

    out = Array{Int32}(undef, nfast, nslow)
    rs = codec.rowstart
    indexed = length(rs) == nslow
    if indexed && Threads.nthreads() > 1
        _agi_decode_indexed!(out, raw, rs, datasize)
    else
        _agi_decode_sequential!(out, raw)
    end
    return out
end

"""Decode every row from the head of the stream, in order. Always correct, never parallel."""
function _agi_decode_sequential!(out::Matrix{Int32}, raw::AbstractVector{UInt8})
    p = 5
    for y in axes(out, 2)
        p = _agi_decode_row!(view(out, :, y), raw, p)
    end
    return out
end

"""
Decode rows independently using the trailing offset table, spreading them over threads.

This is the capability FabIO discards — its decoder reads the same table and comments that
"row indices are ignored" — and it is why the table is worth validating and keeping.
"""
function _agi_decode_indexed!(
    out::Matrix{Int32},
    raw::AbstractVector{UInt8},
    rowstart::Vector{UInt32},
    datasize::Int,
)
    nslow = size(out, 2)
    @inbounds for y = 1:nslow
        Int(rowstart[y]) >= datasize && throw(
            CorruptFileError("AGI bitfield: row $y starts past the end of the data block"),
        )
    end
    Threads.@threads for y = 1:nslow
        _agi_decode_row!(view(out, :, y), raw, 5 + Int(@inbounds rowstart[y]))
    end
    return out
end

decode(c::AGIBitfield, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T} =
    throw(UnsupportedFormatError("AGI bitfield data is Int32; got a request for $T"))

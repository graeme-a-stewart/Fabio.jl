"""
    PCK(overflow_index = Int32[], overflow_value = Int32[])

The CCP4 `pck` codec as used by mar345 image plates.

# Format

The stream is a series of blocks. Each block opens with a 6-bit header read LSB-first:
the low three bits give `1 << n` values in the block, the next three index
`PCK_BIT_COUNT` for the bit width of each value. A width of zero means a run of
zeros. Values are packed at that width and sign-extended.

Those values are not pixels but differences from the truncated mean of four already-decoded
neighbours, so `pck_postdecode!` reconstructs the image. Counts above 65535 do not fit
and are carried separately in an overflow table, which in a mar345 file sits *before* the
packed stream; the format hands it to the codec here, the same way [`AGIBitfield`](@ref)
receives its row index.
"""
struct PCK <: AbstractDataCodec
    overflow_index::Vector{Int32}
    overflow_value::Vector{Int32}
end
PCK() = PCK(Int32[], Int32[])

"""Bit widths addressed by the second three bits of a PCK block header."""
const PCK_BIT_COUNT = (0, 4, 5, 6, 7, 8, 16, 32)

const PCK_BLOCK_HEADER_LENGTH = 6

"""Byte `i` (0-based) of `raw`, or zero past the end, matching the reference decoder."""
@inline _pck_byte(raw::AbstractVector{UInt8}, i::Int) =
    (i >= 0 && i < length(raw)) ? (@inbounds raw[i+1]) : 0x00

"""
    pck_unpack(raw, n) -> Vector{Int32}

Bit-unpack `n` difference values from a PCK stream.
"""
function pck_unpack(raw::AbstractVector{UInt8}, n::Int)
    out = zeros(Int32, n)
    len = length(raw)
    pos = 0        # 0-based byte position
    offset = 0     # bit offset within that byte
    k = 0          # values written so far

    while pos < len && k < n
        value = Int(_pck_byte(raw, pos))
        if offset > 8 - PCK_BLOCK_HEADER_LENGTH
            pos += 1
            value |= Int(_pck_byte(raw, pos)) << 8
            value >>= offset
            offset += PCK_BLOCK_HEADER_LENGTH - 8
        elseif offset == 8 - PCK_BLOCK_HEADER_LENGTH
            value >>= offset
            pos += 1
            offset = 0
        else
            value >>= offset
            offset += PCK_BLOCK_HEADER_LENGTH
        end

        nvals = 1 << (value & 7)
        nbits = PCK_BIT_COUNT[((value >> 3) & 7)+1]

        if nbits == 0
            k += nvals                       # a run of zeros: the array is already zeroed
        else
            k + nvals > n && (nvals = n - k)  # never write past the frame
            nvals <= 0 && break
            pos, offset = _pck_unpack_block!(out, k, raw, pos, offset, nvals, nbits)
            k += nvals
        end
    end
    return out
end

function _pck_unpack_block!(
    out::Vector{Int32},
    k::Int,
    raw::AbstractVector{UInt8},
    pos::Int,
    offset::Int,
    nvals::Int,
    nbits::Int,
)
    startpos, startoffset = pos, offset
    mask = (UInt64(1) << nbits) - UInt64(1)
    @inbounds for i = 0:(nvals-1)
        tmp = UInt64(_pck_byte(raw, pos)) >> offset
        newoffset = nbits + offset
        toread = (newoffset + 7) ÷ 8
        for j = 1:(toread-1)
            tmp |= UInt64(_pck_byte(raw, pos + j)) << (8 * j - offset)
        end
        cur = Int64(tmp & mask)
        # Sign-extend from the value's own width.
        if (cur >> (nbits - 1)) != 0
            cur |= (-1) << (nbits - 1)
        end
        out[k+i+1] = cur % Int32
        pos += newoffset ÷ 8
        offset = newoffset % 8
    end
    # The reference decoder recomputes the position from the block size rather than from the
    # per-value walk; keep that authoritative so a partial block cannot desynchronise us.
    total = startoffset + nbits * nvals
    return startpos + total ÷ 8, total % 8
end

"""
    pck_postdecode!(comp, width) -> Vector{UInt32}

Reconstruct pixels from PCK differences.

Each pixel was stored as its difference from `(up-left + up + up-right + left + 2) / 4`, with
the first pixel and the first row (plus one pixel) using only the preceding value.

The running values are held in **`Int16` and are expected to overflow**. That is not an
oversight: the original mar345 implementation does its post-decompression arithmetic in 16-bit
integers, and real files were written by encoders that wrapped the same way, so reproducing the
overflow bit-for-bit is what makes the output match. FabIO's comment on the same code reads
"This part implementes overlows of int16 as the reference implementation is bugged". The
division truncates toward zero, as C's does.
"""
function pck_postdecode!(comp::Vector{Int32}, width::Int)
    size = length(comp)
    img = zeros(UInt32, size)
    size == 0 && return img

    # First pixel. Note the reference assigns an Int16 into a UInt32 slot without an
    # intermediate cast, so a negative value sign-extends; mirror that exactly.
    last = comp[1] % Int16
    @inbounds img[1] = reinterpret(UInt32, Int32(last))

    # First row, plus one pixel: difference from the previous value only.
    @inbounds for i = 1:min(width, size - 1)
        cur = (comp[i+1] + Int32(last)) % Int16
        img[i+1] = reinterpret(UInt32, Int32(cur))
        last = cur
    end

    size <= width + 1 && return img

    fl0 = img[1] % Int16
    fl1 = img[2] % Int16
    fl2 = img[3] % Int16
    @inbounds for i = (width+1):(size-1)          # 0-based index, as in the reference
        s = Int32(last) + Int32(fl0) + Int32(fl1) + Int32(fl2) + Int32(2)
        cur = (comp[i+1] + div(s, 4)) % Int16     # div truncates toward zero, like C
        img[i+1] = UInt32(reinterpret(UInt16, cur))   # explicit 16-bit crop, then widen
        last = cur
        fl0 = fl1
        fl1 = fl2
        fl2 = img[i-width+3] % Int16
    end
    return img
end

function decode(codec::PCK, raw::AbstractVector{UInt8}, ::Type{UInt32}, dims::Dims{2})
    nfast, nslow = dims
    comp = pck_unpack(raw, nfast * nslow)
    flat = pck_postdecode!(comp, nfast)
    out = reshape(flat, dims)

    # Counts that did not fit in 16 bits are patched in from the overflow table. Indices are
    # 1-based flat positions in raster order, which is exactly this array's memory order.
    idx = codec.overflow_index
    val = codec.overflow_value
    n = length(out)
    @inbounds for i in eachindex(idx)
        j = Int(idx[i])
        (j >= 1 && j <= n) || continue
        out[j] = reinterpret(UInt32, val[i])
    end
    return out
end

decode(::PCK, ::AbstractVector{UInt8}, ::Type{T}, ::Dims{2}) where {T} =
    throw(UnsupportedFormatError("PCK data is UInt32; got a request for $T"))

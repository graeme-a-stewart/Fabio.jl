"""
    Fit2DMask <: ImageFormat

Andy Hammersley's Fit2D mask format: a bit per pixel, one for masked and zero for kept.

# On-disk structure

    byte 0    "MASK" written as four little-endian Int32 words, so the bytes are
              'M' 0 0 0 'A' 0 0 0 'S' 0 0 0 'K' 0 0 0
    byte 16   dim1 (fast axis) as Int32
    byte 20   dim2 (slow axis) as Int32
    byte 1024 the bits: each row occupies `cld(dim1, 32)` Int32 words, so rows begin on a
              four-byte boundary and any bits past `dim1` are padding

Bits run **least significant first** within each byte, the opposite of a Netpbm `P4` bitmap,
which is the kind of detail that produces a mirrored mask if guessed. The result is `UInt8`
zeros and ones rather than a `Bool` array, matching FabIO and keeping the mask usable as a
multiplicative weight.
"""
struct Fit2DMask <: ImageFormat end

"""Fit2D's bit packing: rows of `Int32` words, least significant bit first."""
struct Fit2DMaskBits <: AbstractDataCodec end

const FIT2D_MASK_HEADER_BYTES = 1024

function decode(::Fit2DMaskBits, raw::AbstractVector{UInt8}, ::Type{UInt8}, dims::Dims{2})
    nfast, nslow = dims
    rowbytes = cld(nfast, 32) * 4          # whole Int32 words per row
    length(raw) < rowbytes * nslow &&
        throw(TruncatedFileError("Fit2D mask: needs $(rowbytes * nslow) bytes of bits"))
    out = Array{UInt8}(undef, dims)
    @inbounds for y = 1:nslow
        base = (y - 1) * rowbytes
        for x = 1:nfast
            byte = raw[base+((x-1)>>3)+1]
            out[x, y] = (byte >> ((x - 1) & 7)) & 0x01
        end
    end
    return out
end

function encode(::Fit2DMaskBits, A::AbstractArray{<:Integer,2})
    nfast, nslow = size(A)
    rowbytes = cld(nfast, 32) * 4
    out = zeros(UInt8, rowbytes * nslow)
    @inbounds for y = 1:nslow, x = 1:nfast
        A[x, y] == 0 && continue
        out[(y-1)*rowbytes+((x-1)>>3)+1] |= UInt8(1) << ((x - 1) & 7)
    end
    return out
end

_fixbyteorder!(A, ::ByteOrder, ::Fit2DMaskBits) = A

function scan(::Fit2DMask, src::AbstractSource)
    n = filesize(src)
    n < FIT2D_MASK_HEADER_BYTES &&
        throw(TruncatedFileError("Fit2D mask: file is shorter than its 1024-byte header"))
    raw = bytes(src, 0, FIT2D_MASK_HEADER_BYTES)
    for (i, c) in enumerate("MASK")
        raw[4*(i-1)+1] == UInt8(c) ||
            throw(CorruptFileError("Fit2D mask: missing the MASK stamp"))
    end

    d1 = Int(_load_i32(raw, 17))
    d2 = Int(_load_i32(raw, 21))
    (d1 > 0 && d2 > 0) ||
        throw(CorruptFileError("Fit2D mask: nonsensical dimensions ($d1, $d2)"))

    h = Header()
    h["SUBFORMAT"] = "fit2dmask"
    h["Dim_1"] = d1
    h["Dim_2"] = d2

    nbytes = cld(d1, 32) * 4 * d2
    FIT2D_MASK_HEADER_BYTES + nbytes > n &&
        throw(TruncatedFileError("Fit2D mask: needs $nbytes bytes of bits, file holds $(n - FIT2D_MASK_HEADER_BYTES)"))

    layout = BinaryLayout{UInt8}(
        FIT2D_MASK_HEADER_BYTES,
        nbytes,
        (d1, d2);
        byteorder = LittleEndian(),
        codec = Fit2DMaskBits(),
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""A mask is a bit per pixel: anything non-zero becomes one."""
coerce(::Fit2DMask, A::AbstractArray) = UInt8.(A .!= 0)

"""
    writefit2dmask(path, A)

Write a Fit2D mask. Any non-zero element is masked.
"""
function writefit2dmask(path::AbstractString, A::AbstractArray{<:Any,2})
    B = coerce(Fit2DMask(), A)
    d1, d2 = size(B)
    hdr = zeros(UInt8, FIT2D_MASK_HEADER_BYTES)
    for (i, c) in enumerate("MASK")
        hdr[4*(i-1)+1] = UInt8(c)
    end
    hdr[17:20] = reinterpret(UInt8, [htol(Int32(d1))])
    hdr[21:24] = reinterpret(UInt8, [htol(Int32(d2))])
    Base.open(path, "w") do f
        Base.write(f, hdr)
        Base.write(f, encode(Fit2DMaskBits(), B))
    end
    return path
end

"""Generic write entry point. A mask carries no header. See [`writeformat`](@ref)."""
writeformat(fmt::Fit2DMask, path::AbstractString, arrays::AbstractVector, headers::AbstractVector) =
    writeone((p, a, _h) -> writefit2dmask(p, a), fmt, path, arrays, headers)

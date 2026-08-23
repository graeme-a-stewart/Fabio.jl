"""
    OXD <: ImageFormat

Oxford Diffraction / KM4 CCD frames (`.img`), as written by CrysAlis and its predecessors.
The first Phase 2 format with real compression: two schemes, `TY1` and `TY5`, both differential
with byte escapes, and an uncompressed variant.

# On-disk structure

    byte 0     an ASCII block: version, compression name, NX, NY, the escape-table counts
               OI and OL, and the size of each binary section that follows
    …          five binary sections — general, special, KM4, statistic, history — at fixed
               offsets within themselves, all little-endian
    Header Size In Bytes    the pixels

# The two codecs

`OxdTY1` stores one byte per pixel holding a difference from the *running total*,
biased by 127, with two escapes: a byte of 254 takes the next value from a separate `Int16`
table and 255 from an `Int32` table. Both tables follow the byte plane, sized by `OI` and `OL`.
The image is the cumulative sum over the whole frame.

`OxdTY5` is a single interleaved stream — the escapes sit inline rather than in tables
— and its differences are **per row**, restarting at zero on each new row rather than
accumulating across the frame.

# Two divergences from FabIO

FabIO restarts a TY5 row every `NY` pixels, using the slow dimension where the row length is
the fast one. On the square detectors this format usually comes from the two are equal and the
bug is invisible; on a non-square frame it would shear the image. Rows restart every `NX`
pixels here.

FabIO's statistic keys carry a trailing space — `"Stat: Min "` — which is plainly accidental
and makes them awkward to reach. They are stripped here.

FabIO also picks the element type from the decoded maximum, so the same format yields `Int8`
through `Int64` depending on what the frame happens to contain. That makes the type unknowable
before decoding, which this package settles at scan time, so TY1 and TY5 frames are always
`Int32` — comfortably wide for photon counts. A running total that would exceed it raises
rather than wrapping.
"""
struct OXD <: ImageFormat end

"""Field kinds in the OXD binary sections."""
@enum OxdKind OxdU16 OxdI16 OxdU32 OxdI32 OxdF64

const OXD_GENERAL_FIELDS = (
    (   0, "Binning in x", OxdU16),
    (   2, "Binning in y", OxdU16),
    (  22, "Detector size x", OxdU16),
    (  24, "Detector size y", OxdU16),
    (  26, "Pixels in x", OxdU16),
    (  28, "Pixels in y", OxdU16),
    (  36, "No of pixels", OxdU32),
)

const OXD_SPECIAL_FIELDS = (
    (  56, "Gain", OxdF64),
    ( 464, "Overflows flag", OxdI16),
    ( 472, "Overflow threshold", OxdI32),
    ( 480, "Exposure time in sec", OxdF64),
    ( 488, "Overflow time in sec", OxdF64),
    ( 544, "Unwarping", OxdI32),
    ( 568, "Real pixel size x (mm)", OxdF64),
    ( 576, "Real pixel size y (mm)", OxdF64),
)

const OXD_KM4_FIELDS = (
    ( 552, "Beam rot in deg (e2)", OxdF64),
    ( 560, "Beam rot in deg (e3)", OxdF64),
    ( 568, "Wavelength alpha1", OxdF64),
    ( 576, "Wavelength alpha2", OxdF64),
    ( 584, "Wavelength alpha", OxdF64),
    ( 592, "Wavelength beta", OxdF64),
    ( 640, "Detector tilt e1 in deg", OxdF64),
    ( 648, "Detector tilt e2 in deg", OxdF64),
    ( 656, "Detector tilt e3 in deg", OxdF64),
    ( 664, "Beam center x", OxdF64),
    ( 672, "Beam center y", OxdF64),
    ( 680, "Alpha angle in deg", OxdF64),
    ( 688, "Beta angle in deg", OxdF64),
    ( 712, "Distance in mm", OxdF64),
)

const OXD_STATISTIC_FIELDS = (
    (   0, "Stat: Min", OxdI32),
    (   4, "Stat: Max", OxdI32),
    (  24, "Stat: Average", OxdF64),
    (  40, "Stat: Skewness", OxdF64),
)

"""
`Stat: Stddev` is stored as a variance and exposed as its square root, following FabIO.
It sits at offset 32 of the statistic section.
"""
const OXD_STDDEV_OFFSET = 32

"""
    OxdTY1(nescape16, nescape32)

Oxford's byte-offset scheme. One byte per pixel biased by 127; 254 escapes to the next `Int16`
in a table that follows the byte plane, 255 to the next `Int32` in the table after that. The
image is the cumulative sum across the whole frame.
"""
struct OxdTY1 <: AbstractDataCodec
    nescape16::Int
    nescape32::Int
end

"""
    OxdTY5(nfast)

Oxford's later scheme. The escapes are inline rather than tabulated, and differences restart
at zero on every row, so `nfast` is needed to know where a row begins.
"""
struct OxdTY5 <: AbstractDataCodec
    nfast::Int
end

_fixbyteorder!(A, ::ByteOrder, ::OxdTY1) = A
_fixbyteorder!(A, ::ByteOrder, ::OxdTY5) = A

@inline function _oxd_accumulate(acc::Int64, delta::Int64)
    v = acc + delta
    (v > typemax(Int32) || v < typemin(Int32)) && throw(
        CorruptFileError("OXD: running total $v does not fit in Int32"),
    )
    return v
end

function decode(c::OxdTY1, raw::AbstractVector{UInt8}, ::Type{Int32}, dims::Dims{2})
    n = prod(dims)
    length(raw) < n && throw(TruncatedFileError("OXD: TY1 byte plane is short"))
    off16 = n
    off32 = off16 + 2 * c.nescape16
    off32 + 4 * c.nescape32 > length(raw) &&
        throw(TruncatedFileError("OXD: TY1 escape tables do not fit"))

    out = Array{Int32}(undef, dims)
    acc = Int64(0)
    k16 = 0
    k32 = 0
    @inbounds for i = 1:n
        b = raw[i]
        delta = if b == 0xFE                      # 254: next Int16
            k16 += 1
            k16 <= c.nescape16 ||
                throw(CorruptFileError("OXD: more 16-bit escapes than the header declares"))
            Int64(_load_i16(raw, off16 + 2k16 - 1))
        elseif b == 0xFF                          # 255: next Int32
            k32 += 1
            k32 <= c.nescape32 ||
                throw(CorruptFileError("OXD: more 32-bit escapes than the header declares"))
            Int64(_load_i32(raw, off32 + 4k32 - 3))
        else
            Int64(b) - 127
        end
        acc = _oxd_accumulate(acc, delta)
        out[i] = acc % Int32
    end
    return out
end

function decode(c::OxdTY5, raw::AbstractVector{UInt8}, ::Type{Int32}, dims::Dims{2})
    n = prod(dims)
    out = Array{Int32}(undef, dims)
    pos = 1
    len = length(raw)
    acc = Int64(0)
    @inbounds for i = 1:n
        # Differences restart on every row, so the first pixel of a row is its own value.
        (i - 1) % c.nfast == 0 && (acc = Int64(0))
        pos > len && throw(TruncatedFileError("OXD: TY5 stream ended after $(i - 1) of $n"))
        b = raw[pos]
        delta = if b < 0xFE
            pos += 1
            Int64(b) - 127
        elseif b == 0xFE
            pos + 2 > len && throw(TruncatedFileError("OXD: truncated TY5 16-bit escape"))
            v = Int64(_load_i16(raw, pos + 1))
            pos += 3
            v
        else
            pos + 4 > len && throw(TruncatedFileError("OXD: truncated TY5 32-bit escape"))
            v = Int64(_load_i32(raw, pos + 1))
            pos += 5
            v
        end
        acc = _oxd_accumulate(acc, delta)
        out[i] = acc % Int32
    end
    return out
end

const OXD_SECTIONS = (
    ("General Section size in Byte", OXD_GENERAL_FIELDS),
    ("Special Section size in Byte", OXD_SPECIAL_FIELDS),
    ("KM4 Section size in Byte", OXD_KM4_FIELDS),
    ("Statistic Section in Byte", OXD_STATISTIC_FIELDS),
)

function scan(::OXD, src::AbstractSource)
    n = filesize(src)
    n < 256 && throw(TruncatedFileError("OXD: file is shorter than its ASCII header"))
    ascii = String(Char.(bytes(src, 0, min(n, 512))))
    lines = split(ascii, '\n')
    length(lines) < 6 && throw(CorruptFileError("OXD: ASCII header has too few lines"))

    h = Header()
    h["Header Version"] = String(rstrip(lines[1], ['\r', ' ']))
    h["Compression"] = String(strip(lines[2][13:min(15, length(lines[2]))]))
    l3 = lines[3]
    h["NX"] = _oxd_int(l3, 4, 7)
    h["NY"] = _oxd_int(l3, 12, 15)
    h["OI"] = _oxd_int(l3, 20, 26)
    h["OL"] = _oxd_int(l3, 31, 37)
    l4 = lines[4]
    h["Header Size In Bytes"] = _oxd_int(l4, 9, 15)
    h["General Section size in Byte"] = _oxd_int(l4, 20, 26)
    h["Special Section size in Byte"] = _oxd_int(l4, 31, 37)
    h["KM4 Section size in Byte"] = _oxd_int(l4, 42, 48)
    h["Statistic Section in Byte"] = _oxd_int(l4, 53, 59)
    h["History Section in Byte"] = _oxd_int(l4, 64, length(l4))
    h["NSUPPLEMENT"] = _oxd_int(lines[5], 13, 19)
    h["Time"] = String(strip(lines[6][6:min(29, length(lines[6]))]))

    version = something(tryparse(Float64, get(split(h["Header Version"]), 3, "0")), 0.0)
    asciisize = if version < 4.0
        h["Header Size In Bytes"] - (
            h["General Section size in Byte"] + h["Special Section size in Byte"] +
            h["KM4 Section size in Byte"] + h["Statistic Section in Byte"] +
            h["History Section in Byte"])
    else
        256
    end
    h["ASCII Section size in Byte"] = asciisize

    pos = asciisize
    for (sizekey, fields) in OXD_SECTIONS
        size = h[sizekey]
        (size <= 0 || pos + size > n) && (pos += max(size, 0); continue)
        block = bytes(src, pos, size)
        for (off, name, kind) in fields
            off + _oxd_width(kind) > size && continue
            h[name] = _oxd_value(block, off + 1, kind)
        end
        if sizekey == "Statistic Section in Byte" && OXD_STDDEV_OFFSET + 8 <= size
            variance = _oxd_value(block, OXD_STDDEV_OFFSET + 1, OxdF64)
            h["Stat: Stddev"] = variance >= 0 ? sqrt(variance) : NaN
        end
        pos += size
    end

    d1 = h["NX"]
    d2 = h["NY"]
    (d1 > 0 && d2 > 0) || throw(CorruptFileError("OXD: nonsensical NX/NY ($d1, $d2)"))
    dataoffset = h["Header Size In Bytes"]
    (dataoffset > 0 && dataoffset < n) ||
        throw(CorruptFileError("OXD: Header Size In Bytes is $dataoffset in a $n-byte file"))

    compression = h["Compression"]
    T, codec, nbytes = if compression == "TY1"
        (Int32, OxdTY1(h["OI"], h["OL"]), d1 * d2 + 2 * h["OI"] + 4 * h["OL"])
    elseif compression == "TY5"
        (Int32, OxdTY5(d1), n - dataoffset)
    elseif compression in ("NO", "")
        (Int32, RawBlob(), d1 * d2 * 4)
    else
        throw(UnsupportedFormatError("OXD compression $(repr(compression)) is not supported"))
    end
    dataoffset + nbytes > n &&
        throw(TruncatedFileError("OXD: needs $nbytes bytes of pixels at $dataoffset"))

    layout = BinaryLayout{T}(
        dataoffset, nbytes, (d1, d2); byteorder = LittleEndian(), codec = codec)
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""Parse a fixed-column integer field from an ASCII header line."""
function _oxd_int(line::AbstractString, from::Int, to::Int)
    to = min(to, length(line))
    from > to && return 0
    return something(tryparse(Int, strip(line[from:to])), 0)
end

_oxd_width(k::OxdKind) = k == OxdU16 || k == OxdI16 ? 2 : k == OxdF64 ? 8 : 4

function _oxd_value(block::AbstractVector{UInt8}, i::Int, k::OxdKind)
    k == OxdU16 && return Int(_load_u16(block, i))
    k == OxdI16 && return Int(reinterpret(Int16, _load_u16(block, i)))
    k == OxdU32 && return Int(_load_u32(block, i))
    k == OxdI32 && return Int(_load_i32(block, i))
    return Float64(reinterpret(Float64, _load_u64(block, i)))
end

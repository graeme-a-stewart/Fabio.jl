"""
    Mar345 <: ImageFormat

mar345 / mar300 image-plate files, as written by MAR Research detectors. Extensions carry the
plate size — `.mar2300`, `.mar3450`, and so on — which is why the format registers so many.

# On-disk structure

    byte 0     16 big- or little-endian Int32s; the first is 1234, which fixes the byte order
               [1] width, [2] number of overflow pixels, [3] format, [5] total pixels,
               [6..15] pixel size, wavelength, distance and the goniometer angles
    byte 64    ASCII header from "mar research" to "END OF HEADER", padded to 4096 bytes
    …          the overflow table: `ceil(nhigh/8)` records of 64 bytes, each 8 pairs of
               Int32 (1-based flat index, value), ending one byte before the key below
    …          "CCP4 packed image, X: " (v1) or "CCP4 packed image V2, X: " (v2)
               followed by 13 bytes giving the two dimensions as "%4d, Y: %4d"
    …          the PCK stream, after any leading whitespace

The overflow table preceding the pixel data is the reason [`PCK`](@ref) takes it as a
parameter rather than discovering it: by the time the codec runs, the format has already read
it.
"""
struct Mar345 <: ImageFormat end

const MAR345_KEY_V1 = "CCP4 packed image, X: "
const MAR345_KEY_V2 = "CCP4 packed image V2, X: "
const MAR345_HEADER_BYTES = 4096
const MAR345_PACK_SIZE_HIGH = 8

"""Names of the 16 leading binary header words, with the scale each is stored at."""
const MAR345_BINARY_FIELDS = (
    (2, "Width", 1.0),
    (3, "NumHigh", 1.0),
    (4, "FormatCode", 1.0),
    (5, "ModeCode", 1.0),
    (6, "NumPixels", 1.0),
    (7, "PixelLength", 1e-3),
    (8, "PixelHeight", 1e-3),
    (9, "Wavelength", 1e-6),
    (10, "Distance", 1e-3),
    (11, "StartPhi", 1e-3),
    (12, "EndPhi", 1e-3),
    (13, "StartOmega", 1e-3),
    (14, "EndOmega", 1e-3),
    (15, "Chi", 1e-3),
    (16, "TwoTheta", 1e-3),
)

function scan(::Mar345, src::AbstractSource)
    filesize(src) < MAR345_HEADER_BYTES &&
        throw(TruncatedFileError("mar345: file is shorter than its 4096-byte header"))

    head = bytes(src, 0, 64)
    marker_le = _load_i32(head, 1)
    bigendian = marker_le != 1234
    bigendian && _bswap_i32(_load_i32(head, 1)) != 1234 &&
        throw(CorruptFileError("mar345: leading word is neither 1234 nor its byte swap"))
    word(i) = bigendian ? _bswap_i32(_load_i32(head, 4 * (i - 1) + 1)) : _load_i32(head, 4 * (i - 1) + 1)

    h = Header()
    for (i, name, scale) in MAR345_BINARY_FIELDS
        v = word(i)
        h[name] = scale == 1.0 ? Int(v) : Int(v) * scale
    end
    h["ByteOrder"] = bigendian ? "HighByteFirst" : "LowByteFirst"
    h["Format"] = word(4) == 2 ? "spiral" : "compressed"
    h["Mode"] = word(5) == 1 ? "Time" : "Dose"

    width = Int(word(2))
    npixels = Int(word(6))
    (width > 0 && npixels > 0) ||
        throw(CorruptFileError("mar345: nonsensical width $width or pixel count $npixels"))
    height = npixels ÷ width

    h["Format"] == "compressed" || throw(
        UnsupportedFormatError("mar345: only the compressed (PCK) format is supported, not $(h["Format"])"),
    )

    _mar345_ascii_header!(h, src)

    # Locate the packed section; V2 first, since its key contains the V1 key's prefix.
    keypos, key, version = _mar345_findkey(src)
    sizeoff = keypos + ncodeunits(key)
    sizes = String(Char.(bytes(src, sizeoff, 13)))
    dimx = something(tryparse(Int, strip(sizes[1:4])), width)
    dimy = something(tryparse(Int, strip(sizes[10:13])), height)
    if dimx != width || dimy != height
        width, height = dimx, dimy
    end

    # Skip the whitespace the writer leaves between the size field and the stream.
    dataoffset = sizeoff + 13
    n = filesize(src)
    while dataoffset < n && _byteat(src, dataoffset) in (0x20, 0x0A, 0x0D, 0x09)
        dataoffset += 1
    end

    nhigh = Int(word(3))
    oidx, oval = _mar345_overflow(src, keypos, nhigh, bigendian)
    h["NumHigh"] = nhigh

    layout = BinaryLayout{UInt32}(
        dataoffset,
        n - dataoffset,
        (width, height);
        byteorder = bigendian ? BigEndian() : LittleEndian(),
        codec = PCK(oidx, oval),
    )
    h["PckVersion"] = version
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

@inline _bswap_i32(v::Int32) = bswap(v)

function _mar345_findkey(src::AbstractSource)
    p2 = _findbytes(src, Vector{UInt8}(codeunits(MAR345_KEY_V2)))
    p2 === nothing || return (p2, MAR345_KEY_V2, 2)
    p1 = _findbytes(src, Vector{UInt8}(codeunits(MAR345_KEY_V1)))
    p1 === nothing &&
        throw(CorruptFileError("mar345: no \"CCP4 packed image\" section found"))
    return (p1, MAR345_KEY_V1, 1)
end

"""Parse the ASCII part of the header, between "mar research" and "END OF HEADER"."""
function _mar345_ascii_header!(h::Header, src::AbstractSource)
    block = String(Char.(bytes(src, 64, MAR345_HEADER_BYTES - 64)))
    start = findfirst("mar research", block)
    text = start === nothing ? block : block[first(start):end]
    for raw in split(text, '\n')
        line = strip(raw, ['\0', ' ', '\t', '\r'])
        isempty(line) && continue
        line == "END OF HEADER" && break
        parts = split(line, limit = 2)
        length(parts) == 2 || continue
        key = String(parts[1])
        # Keep the first occurrence: mar345 repeats some keys across its sections.
        haskey(h, key) || (h[key] = String(strip(parts[2])))
    end
    return h
end

"""
Read the overflow table: `ceil(nhigh/8)` records of 64 bytes, ending one byte before the
packed-image key, each holding 8 pairs of `(1-based flat index, value)` `Int32`s.
"""
function _mar345_overflow(src::AbstractSource, keypos::Int, nhigh::Int, bigendian::Bool)
    nhigh <= 0 && return (Int32[], Int32[])
    records = (nhigh + MAR345_PACK_SIZE_HIGH - 1) ÷ MAR345_PACK_SIZE_HIGH
    nbytes = 64 * records
    stop = keypos - 1
    start = stop - nbytes
    start < 0 && throw(
        CorruptFileError("mar345: overflow table of $nbytes bytes does not fit before the packed section"),
    )
    raw = bytes(src, start, nbytes)
    npairs = nbytes ÷ 8
    idx = Vector{Int32}(undef, npairs)
    val = Vector{Int32}(undef, npairs)
    @inbounds for i = 1:npairs
        a = _load_i32(raw, 8 * (i - 1) + 1)
        b = _load_i32(raw, 8 * (i - 1) + 5)
        idx[i] = bigendian ? bswap(a) : a
        val[i] = bigendian ? bswap(b) : b
    end
    return idx, val
end

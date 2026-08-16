"""
    Raxis <: ImageFormat

Rigaku R-AXIS imaging-plate frames.

# On-disk structure

    byte 0     a fixed header of big-endian fields; see [`RAXIS_FIELDS`](@ref)
    …          "X Pixels" and "Y Pixels", at bytes 768 and 772, give the geometry
    end        the pixels, `UInt16` big-endian, positioned by counting **backwards from the
               end of the file** rather than forwards from the header

Reading the pixels from the end is not a quirk of this implementation: the header length varies
between instruments while the pixel block does not, so FabIO seeks from EOF as well.

# The photomultiplier escape

R-AXIS stores counts in 16 bits and escapes anything larger by setting the top bit: such a
pixel holds a *scaled* value, recovered by clearing bit 15 and multiplying by the header's
"Photomultiplier Ratio". A frame containing any escaped pixel is therefore widened to `UInt32`,
so the same detector can produce either element type depending on whether it saturated. The
scan decides which by looking at the stored values, so the type is settled before any frame is
handed out.
"""
struct Raxis <: ImageFormat end

"""Field kinds in the R-AXIS header."""
@enum RaxisKind RaxisStr RaxisI32 RaxisF32

"""
Offset, name, byte width and kind of every R-AXIS header field, following the layout FabIO
records. All numeric fields are big-endian.
"""
const RAXIS_FIELDS = (
    (   0, "InstrumentType", 10, RaxisStr),
    (  10, "Version", 10, RaxisStr),
    (  20, "Crystal Name", 20, RaxisStr),
    (  40, "Crystal System", 12, RaxisStr),
    (  52, "A", 4, RaxisF32),
    (  56, "B", 4, RaxisF32),
    (  60, "C", 4, RaxisF32),
    (  64, "Alpha", 4, RaxisF32),
    (  68, "Beta", 4, RaxisF32),
    (  72, "Gamma", 4, RaxisF32),
    (  76, "Space Group", 12, RaxisStr),
    (  88, "Mosaicity", 4, RaxisF32),
    (  92, "Memo", 80, RaxisStr),
    ( 172, "Date", 12, RaxisStr),
    ( 184, "Reserved Space 1", 84, RaxisStr),
    ( 268, "User", 20, RaxisStr),
    ( 288, "Xray Target", 4, RaxisStr),
    ( 292, "Wavelength", 4, RaxisF32),
    ( 296, "Monochromator", 20, RaxisStr),
    ( 316, "Monochromator 2theta", 4, RaxisF32),
    ( 320, "Collimator", 20, RaxisStr),
    ( 340, "Filter", 4, RaxisStr),
    ( 344, "Crystal-to-detector Distance", 4, RaxisF32),
    ( 348, "Generator Voltage", 4, RaxisF32),
    ( 352, "Generator Current", 4, RaxisF32),
    ( 356, "Focus", 12, RaxisStr),
    ( 368, "Xray Memo", 80, RaxisStr),
    ( 448, "IP shape", 4, RaxisI32),
    ( 452, "Oscillation Type", 4, RaxisF32),
    ( 456, "Reserved Space 2", 56, RaxisStr),
    ( 512, "Crystal Mount (spindle axis)", 4, RaxisStr),
    ( 516, "Crystal Mount (beam axis)", 4, RaxisStr),
    ( 520, "Phi Datum", 4, RaxisF32),
    ( 524, "Phi Oscillation Start", 4, RaxisF32),
    ( 528, "Phi Oscillation Stop", 4, RaxisF32),
    ( 532, "Frame Number", 4, RaxisI32),
    ( 536, "Exposure Time", 4, RaxisF32),
    ( 540, "Direct beam X position", 4, RaxisF32),
    ( 544, "Direct beam Y position", 4, RaxisF32),
    ( 548, "Omega Angle", 4, RaxisF32),
    ( 552, "Chi Angle", 4, RaxisF32),
    ( 556, "2Theta Angle", 4, RaxisF32),
    ( 560, "Mu Angle", 4, RaxisF32),
    ( 564, "Image Template", 204, RaxisStr),
    ( 768, "X Pixels", 4, RaxisI32),
    ( 772, "Y Pixels", 4, RaxisI32),
    ( 776, "X Pixel Length", 4, RaxisF32),
    ( 780, "Y Pixel Length", 4, RaxisF32),
    ( 784, "Record Length", 4, RaxisI32),
    ( 788, "Total", 4, RaxisI32),
    ( 792, "Starting Line", 4, RaxisI32),
    ( 796, "IP Number", 4, RaxisI32),
    ( 800, "Photomultiplier Ratio", 4, RaxisF32),
    ( 804, "Fade Time (to start of read)", 4, RaxisF32),
    ( 808, "Fade Time (to end of read)", 4, RaxisF32),
    ( 812, "Host Type/Endian", 10, RaxisStr),
    ( 822, "IP Type", 10, RaxisStr),
    ( 832, "Horizontal Scan", 4, RaxisI32),
    ( 836, "Vertical Scan", 4, RaxisI32),
    ( 840, "Front/Back Scan", 4, RaxisI32),
    ( 844, "Pixel Shift (RAXIS V)", 4, RaxisF32),
    ( 848, "Even/Odd Intensity Ratio (RAXIS V)", 4, RaxisF32),
    ( 852, "Magic number", 4, RaxisI32),
    ( 856, "Number of Axes", 4, RaxisI32),
    ( 860, "Goniometer Vector ax.1.1", 4, RaxisF32),
    ( 864, "Goniometer Vector ax.1.2", 4, RaxisF32),
    ( 868, "Goniometer Vector ax.1.3", 4, RaxisF32),
    ( 872, "Goniometer Vector ax.2.1", 4, RaxisF32),
    ( 876, "Goniometer Vector ax.2.2", 4, RaxisF32),
    ( 880, "Goniometer Vector ax.2.3", 4, RaxisF32),
    ( 884, "Goniometer Vector ax.3.1", 4, RaxisF32),
    ( 888, "Goniometer Vector ax.3.2", 4, RaxisF32),
    ( 892, "Goniometer Vector ax.3.3", 4, RaxisF32),
    ( 896, "Goniometer Vector ax.4.1", 4, RaxisF32),
    ( 900, "Goniometer Vector ax.4.2", 4, RaxisF32),
    ( 904, "Goniometer Vector ax.4.3", 4, RaxisF32),
    ( 908, "Goniometer Vector ax.5.1", 4, RaxisF32),
    ( 912, "Goniometer Vector ax.5.2", 4, RaxisF32),
    ( 916, "Goniometer Vector ax.5.3", 4, RaxisF32),
    ( 920, "Goniometer Start ax.1", 4, RaxisF32),
    ( 924, "Goniometer Start ax.2", 4, RaxisF32),
    ( 928, "Goniometer Start ax.3", 4, RaxisF32),
    ( 932, "Goniometer Start ax.4", 4, RaxisF32),
    ( 936, "Goniometer Start ax.5", 4, RaxisF32),
    ( 940, "Goniometer End ax.1", 4, RaxisF32),
    ( 944, "Goniometer End ax.2", 4, RaxisF32),
    ( 948, "Goniometer End ax.3", 4, RaxisF32),
    ( 952, "Goniometer End ax.4", 4, RaxisF32),
    ( 956, "Goniometer End ax.5", 4, RaxisF32),
    ( 960, "Goniometer Offset ax.1", 4, RaxisF32),
    ( 964, "Goniometer Offset ax.2", 4, RaxisF32),
    ( 968, "Goniometer Offset ax.3", 4, RaxisF32),
    ( 972, "Goniometer Offset ax.4", 4, RaxisF32),
    ( 976, "Goniometer Offset ax.5", 4, RaxisF32),
    ( 980, "Goniometer Scan Axis", 4, RaxisI32),
    ( 984, "Axes Names", 40, RaxisStr),
    (1024, "file", 16, RaxisStr),
    (1040, "cmnt", 20, RaxisStr),
    (1060, "smpl", 20, RaxisStr),
    (1080, "iext", 4, RaxisI32),
    (1084, "reso", 4, RaxisI32),
    (1088, "save", 4, RaxisI32),
    (1092, "dint", 4, RaxisI32),
    (1096, "byte", 4, RaxisI32),
    (1100, "init", 4, RaxisI32),
    (1104, "ipus", 4, RaxisI32),
    (1108, "dexp", 4, RaxisI32),
    (1112, "expn", 4, RaxisI32),
    (1116, "posx", 20, RaxisStr),
    (1136, "posy", 20, RaxisStr),
    (1156, "xray", 4, RaxisI32),)

const RAXIS_HEADER_BYTES = 1400

"""
    RaxisPM(ratio)

The photomultiplier escape: a stored value with bit 15 set means `(value & 0x7fff) * ratio`.
"""
struct RaxisPM <: AbstractDataCodec
    ratio::Float64
end

function decode(c::RaxisPM, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    n = prod(dims)
    length(raw) < 2n && throw(TruncatedFileError("R-AXIS: short pixel block"))
    out = Array{T}(undef, dims)
    @inbounds for i = 1:n
        v = bswap(_load_u16(raw, 2i - 1))          # stored big-endian
        out[i] = (v & 0x8000) != 0 ? T(round(c.ratio * Float64(v & 0x7fff))) : T(v)
    end
    return out
end

_fixbyteorder!(A, ::ByteOrder, ::RaxisPM) = A

function scan(::Raxis, src::AbstractSource)
    n = filesize(src)
    n < RAXIS_HEADER_BYTES &&
        throw(TruncatedFileError("R-AXIS: file is shorter than its 1400-byte header"))
    raw = bytes(src, 0, RAXIS_HEADER_BYTES)

    h = Header()
    for (off, name, width, kind) in RAXIS_FIELDS
        off + width > RAXIS_HEADER_BYTES && continue
        h[name] = if kind == RaxisStr
            strip(String(Char.(@view raw[(off+1):(off+width)])), ['\0', ' '])
        elseif kind == RaxisI32
            Int(bswap(_load_i32(raw, off + 1)))
        else
            Float64(reinterpret(Float32, bswap(_load_i32(raw, off + 1))))
        end
    end

    d1 = getheader(h, "X Pixels", Int, 0)
    d2 = getheader(h, "Y Pixels", Int, 0)
    (d1 > 0 && d2 > 0) ||
        throw(CorruptFileError("R-AXIS: nonsensical X/Y Pixels ($d1, $d2)"))

    nbytes = d1 * d2 * 2
    nbytes > n - RAXIS_HEADER_BYTES && throw(
        TruncatedFileError("R-AXIS: $(d1)x$(d2) needs $nbytes bytes, file holds $n in total"),
    )
    # The pixels sit at the end, since header lengths vary between instruments.
    dataoffset = n - nbytes

    ratio = getheader(h, "Photomultiplier Ratio", Float64, 1.0)
    escaped = _raxis_has_escapes(src, dataoffset, d1 * d2)
    h["PhotomultiplierApplied"] = escaped
    T = escaped ? UInt32 : UInt16

    layout = BinaryLayout{T}(
        dataoffset,
        nbytes,
        (d1, d2);
        byteorder = BigEndian(),
        codec = RaxisPM(ratio),
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""Whether any stored value has bit 15 set, which decides the element type."""
function _raxis_has_escapes(src::AbstractSource, offset::Int, n::Int)
    raw = bytes(src, offset, 2n)
    @inbounds for i = 1:n
        (raw[2i-1] & 0x80) != 0 && return true      # big-endian, so the top bit is first
    end
    return false
end

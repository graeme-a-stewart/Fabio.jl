"""
    Xcalibur(dims = nothing)

The CrysalisPro `.ccd` chip-characteristics file: a description of a detector's **bad pixels**
— points, rows, columns and polygons — rather than an image. Reading it gives the mask those
records describe, as `UInt8` ones and zeros.

# Why this reader exists at all

FabIO registers an `xcaliburimage` codec, but its `read` is the unmodified `templateimage.py`
boilerplate: it ignores the file, builds a 50×60 array, and then raises `AttributeError`
because the template's `self.uint16` is not an attribute. It cannot read any file.

What FabIO does have is the other direction — a complete set of struct definitions with
`loads`/`dumps`, and a `decompose` that turns a mask array *into* those records for
`eiger2crysalis` to write. The binary layout below is taken from those definitions; the
rasterisation back to a mask is the step FabIO never connected.

# On-disk structure

    byte 0     a fixed 1854-byte prefix: version, dark current, read noise, seven
               256-byte name fields, the FIP60 origin, and the corner masks
    byte 1854  a UInt16 count then that many records, repeated for each kind in order:
               polygons (28 bytes each), points (14), columns (22) at native, 1x1, 2x2 and
               4x4 binning, rows (18), then the scintillator id and two gains, then rows
               again at 1x1, 2x2 and 4x4

Every field is little-endian. Coordinates are `UInt16` and 0-based.

# The shape has to come from somewhere

A `.ccd` records coordinates but not the detector size — in CrysalisPro that comes from the
accompanying `.par` or `.set` file. Pass it if you know it:

    Fabio.openimage(path; format = Xcalibur((2048, 2048)))

Otherwise the mask is sized to just contain the records, which is a lower bound rather than the
detector's real extent, and `DimsInferred` in the header says so.
"""
struct Xcalibur <: ImageFormat
    dims::Union{Nothing,Dims{2}}
end
Xcalibur() = Xcalibur(nothing)

const XCALIBUR_PREFIX_BYTES = 1854
const XCALIBUR_POLYGON_MAXPOINTS = 6

"""Byte width of each record kind, from FabIO's struct definitions."""
const XCALIBUR_POLYGON_SIZE = 2 * (2 + 2 * XCALIBUR_POLYGON_MAXPOINTS)   # 28
const XCALIBUR_POINT_SIZE = 14
const XCALIBUR_ROW_SIZE = 18
const XCALIBUR_COLUMN_SIZE = 22

"""256-byte text fields of the fixed prefix, by name and offset."""
const XCALIBUR_TEXT_FIELDS = (
    (20, "ccharacteristicsfil"),
    (276, "cccdproducer"),
    (532, "cccdchiptype"),
    (788, "cccdchipserial"),
    (1044, "ctaperproducer"),
    (1300, "ctapertype"),
    (1556, "ctaperserial"),
)

"""A rectangle to mask, as (x0, x1, y0, y1) inclusive and 0-based."""
const XcalRect = NTuple{4,Int}

"""Everything a `.ccd` describes, once parsed."""
struct XcaliburRecords
    points::Vector{NTuple{2,Int}}
    rows::Vector{XcalRect}
    columns::Vector{XcalRect}
    polygons::Vector{XcalRect}
end

"""Rasterise parsed `.ccd` records into a mask."""
struct XcaliburMask <: AbstractDataCodec
    records::XcaliburRecords
end

_fixbyteorder!(A, ::ByteOrder, ::XcaliburMask) = A

function decode(c::XcaliburMask, ::AbstractVector{UInt8}, ::Type{UInt8}, dims::Dims{2})
    out = zeros(UInt8, dims)
    nfast, nslow = dims
    mark(x, y) = (1 <= x + 1 <= nfast && 1 <= y + 1 <= nslow) && (out[x+1, y+1] = 0x01)
    for (x, y) in c.records.points
        mark(x, y)
    end
    for r in (c.records.rows..., c.records.columns..., c.records.polygons...)
        x0, x1, y0, y1 = r
        for y = min(y0, y1):max(y0, y1), x = min(x0, x1):max(x0, x1)
            mark(x, y)
        end
    end
    return out
end

function scan(fmt::Xcalibur, src::AbstractSource)
    n = filesize(src)
    n <= XCALIBUR_PREFIX_BYTES && throw(
        TruncatedFileError("Xcalibur: file is $n bytes, shorter than the 1854-byte prefix"),
    )
    raw = bytes(src, 0, n)

    h = Header()
    h["dwversion"] = Int(_load_u32(raw, 1))
    h["ddarkcurrentinADUpersec"] = reinterpret(Float64, _load_u64(raw, 5))
    h["dreadnoiseinADU"] = reinterpret(Float64, _load_u64(raw, 13))
    for (off, name) in XCALIBUR_TEXT_FIELDS
        h[name] = strip(String(Char.(@view raw[(off+1):(off+256)])), ['\0', ' '])
    end
    h["iisfip60origin"] = Int(_load_u16(raw, 1813))
    h["ifip60xorigin"] = Int(_load_u16(raw, 1815))
    h["ifip60yorigin"] = Int(_load_u16(raw, 1817))
    h["inumofcornermasks"] = Int(_load_u16(raw, 1819))
    h["inumofglowingcornermasks"] = Int(_load_u16(raw, 1837))

    pos = XCALIBUR_PREFIX_BYTES
    points = NTuple{2,Int}[]
    rows = XcalRect[]
    columns = XcalRect[]
    polygons = XcalRect[]

    pos = _xcal_list!(h, raw, pos, n, "ibadpolygons", XCALIBUR_POLYGON_SIZE) do buf, off
        push!(polygons, _xcal_polygon(buf, off))
    end
    pos = _xcal_list!(h, raw, pos, n, "ibadpoints", XCALIBUR_POINT_SIZE) do buf, off
        push!(points, (Int(_load_u16(buf, off)), Int(_load_u16(buf, off + 2))))
    end
    for key in ("ibadcolumns", "ibadcolumns1x1", "ibadcolumns2x2", "ibadcolumns4x4")
        pos = _xcal_list!(h, raw, pos, n, key, XCALIBUR_COLUMN_SIZE) do buf, off
            push!(columns, _xcal_span(buf, off))
        end
    end
    pos = _xcal_list!(h, raw, pos, n, "ibadrows", XCALIBUR_ROW_SIZE) do buf, off
        push!(rows, _xcal_span(buf, off))
    end
    # The scintillator id and its two gains sit between the native rows and the binned ones.
    if pos + 18 <= n
        h["iscintillatorid"] = Int(_load_u16(raw, pos + 1))
        h["dgain_mo"] = reinterpret(Float64, _load_u64(raw, pos + 3))
        h["dgain_cu"] = reinterpret(Float64, _load_u64(raw, pos + 11))
        pos += 18
    end
    for key in ("ibadrows1x1", "ibadrows2x2", "ibadrows4x4")
        pos = _xcal_list!(h, raw, pos, n, key, XCALIBUR_ROW_SIZE) do buf, off
            push!(rows, _xcal_span(buf, off))
        end
    end

    records = XcaliburRecords(points, rows, columns, polygons)
    dims, inferred = _xcal_dims(fmt, records)
    h["DimsInferred"] = inferred
    h["MaskedRecords"] =
        length(points) + length(rows) + length(columns) + length(polygons)

    layout = BinaryLayout{UInt8}(
        0, 0, dims; byteorder = LittleEndian(), codec = XcaliburMask(records))
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""Read a `UInt16` count followed by that many fixed-size records, calling `f` on each."""
function _xcal_list!(f, h::Header, raw, pos::Int, n::Int, key::AbstractString, size::Int)
    pos + 2 > n && return n
    count = Int(_load_u16(raw, pos + 1))
    pos += 2
    h[key] = count
    pos + count * size > n && throw(
        TruncatedFileError("Xcalibur: $key claims $count records, which do not fit"),
    )
    for k = 0:(count-1)
        f(raw, pos + k * size + 1)
    end
    return pos + count * size
end

"""A row or column record: start and end points, then replacements and flags we ignore."""
function _xcal_span(buf, off::Int)
    x0 = Int(_load_u16(buf, off))
    y0 = Int(_load_u16(buf, off + 2))
    x1 = Int(_load_u16(buf, off + 4))
    y1 = Int(_load_u16(buf, off + 6))
    return (x0, x1, y0, y1)
end

"""A polygon record: type, point count, then six x and six y coordinates."""
function _xcal_polygon(buf, off::Int)
    npts = Int(_load_u16(buf, off + 2))
    npts = clamp(npts, 0, XCALIBUR_POLYGON_MAXPOINTS)
    npts == 0 && return (0, -1, 0, -1)          # an empty span masks nothing
    xs = [Int(_load_u16(buf, off + 4 + 2(k - 1))) for k = 1:npts]
    ys = [Int(_load_u16(buf, off + 4 + 2 * XCALIBUR_POLYGON_MAXPOINTS + 2(k - 1))) for k = 1:npts]
    # Every polygon CrysalisPro writes is a rectangle, so its bounding box is the shape
    # itself; a general polygon would be filled conservatively by its bounds.
    return (minimum(xs), maximum(xs), minimum(ys), maximum(ys))
end

"""The mask shape: as given, or just large enough to hold every record."""
function _xcal_dims(fmt::Xcalibur, r::XcaliburRecords)
    fmt.dims === nothing || return (fmt.dims, false)
    maxx = 0
    maxy = 0
    for (x, y) in r.points
        maxx = max(maxx, x)
        maxy = max(maxy, y)
    end
    for s in (r.rows..., r.columns..., r.polygons...)
        maxx = max(maxx, s[1], s[2])
        maxy = max(maxy, s[3], s[4])
    end
    return ((max(maxx + 1, 1), max(maxy + 1, 1)), true)
end

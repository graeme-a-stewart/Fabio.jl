"""
    DM3 <: ImageFormat

Gatan Digital Micrograph files (`.dm3`). Unlike every other format here, the metadata is a
**tree**: named tag groups nesting to arbitrary depth, with the image somewhere inside it.

# On-disk structure

    byte 0   version, big-endian UInt32, must be 3
    byte 4   total bytes in the file
    byte 8   byte order of stored *values*: 0 big, 1 little
    byte 12  the root tag group

A tag group is a sorted flag, an open flag, and a count of entries. Each entry is a kind byte —
20 for a nested group, 21 for data — a big-endian UInt16 label length, the label, and then for
data a `%%%%` marker followed by the encoded type. The tag structure itself is always
big-endian; only the values follow the file's declared order.

# Keys are paths

FabIO keeps only the leaf label, so a tag deeper in the tree overwrites a shallower one of the
same name and it logs when that happens. That matters here more than it sounds: a `.dm3` with a
thumbnail holds **two** arrays called `Data`, and which one FabIO returns depends on their
order in the file. Keys here are the full dotted path, so nothing is lost, and the image is
chosen by position and size — the largest array at `…ImageData.Data` — rather than by being
last, so neither a thumbnail nor a long text tag can win.

# Large arrays are not loaded into the header

An array of more than `DM3_INLINE_LIMIT` elements is recorded by shape and offset
rather than read, so opening a file does not pull its thumbnail and image into the header
alongside the frame.
"""
struct DM3 <: ImageFormat end

"""Arrays longer than this are described in the header rather than read into it."""
const DM3_INLINE_LIMIT = 4096

"""Encoded type codes, as Digital Micrograph writes them."""
const DM3_TYPES = Dict{Int,DataType}(
    2 => Int16,
    3 => Int32,
    4 => UInt16,
    5 => UInt32,
    6 => Float32,
    7 => Float64,
    8 => Int8,
    9 => Int8,      # boolean, one byte
    10 => Int8,     # octet
    11 => Int64,
    12 => UInt64,
)

const DM3_STRUCT = 15
const DM3_ARRAY = 20
const DM3_GROUP_ENTRY = 20
const DM3_DATA_ENTRY = 21

"""One array found in the tree: where it is, what it holds, and how many elements."""
struct Dm3Array
    offset::Int
    eltype::DataType
    count::Int
    path::String
end

function scan(::DM3, src::AbstractSource)
    n = filesize(src)
    n < 16 && throw(TruncatedFileError("DM3: file is too short for a header"))
    head = bytes(src, 0, 12)
    version = Int(bswap(_load_u32(head, 1)))
    version == 3 ||
        throw(UnsupportedFormatError("DM3: version $version is not supported (only 3)"))
    declared = Int(bswap(_load_u32(head, 5)))
    orderflag = Int(bswap(_load_u32(head, 9)))
    orderflag in (0, 1) ||
        throw(CorruptFileError("DM3: byte-order flag is $orderflag, neither 0 nor 1"))
    little = orderflag == 1

    h = Header()
    h["Version"] = version
    h["BytesInFile"] = declared
    h["ByteOrder"] = little ? "LowByteFirst" : "HighByteFirst"

    arrays = Dm3Array[]
    limit = min(n, declared > 0 ? declared + 16 : n)
    _dm3_group!(h, arrays, src, 12, limit, little, "", 0)

    isempty(arrays) && throw(CorruptFileError("DM3: no array found in the tag tree"))
    img = _dm3_pick(arrays)
    dims = _dm3_dims(h, img)

    layout = BinaryLayout{img.eltype}(
        img.offset,
        img.count * sizeof(img.eltype),
        dims;
        byteorder = little ? LittleEndian() : BigEndian(),
        codec = RawBlob(),
    )
    h["ImagePath"] = img.path
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""
Choose the image among the arrays found.

Digital Micrograph puts it at `…ImageData.Data`, so prefer those; a file with a thumbnail has
several and the largest is the image. Failing that convention, fall back to the largest array
of any name.
"""
function _dm3_pick(arrays::Vector{Dm3Array})
    canonical = filter(a -> endswith(a.path, "ImageData.Data"), arrays)
    return argmax(a -> a.count, isempty(canonical) ? arrays : canonical)
end

"""Read a tag group and its entries, recursing into nested groups. Returns the position after."""
function _dm3_group!(
    h::Header,
    arrays::Vector{Dm3Array},
    src::AbstractSource,
    pos::Int,
    limit::Int,
    little::Bool,
    prefix::String,
    depth::Int,
)
    depth > 64 && throw(CorruptFileError("DM3: tag tree deeper than 64 levels"))
    pos + 6 > limit && return pos
    ntags = Int(bswap(_load_u32(bytes(src, pos + 2, 4), 1)))
    pos += 6
    (0 <= ntags <= 1_000_000) ||
        throw(CorruptFileError("DM3: tag group claims $ntags entries"))

    for i = 1:ntags
        pos + 3 > limit && break
        kind = Int(_byteat(src, pos))
        labellen = Int(bswap(_load_u16(bytes(src, pos + 1, 2), 1)))
        pos += 3
        pos + labellen > limit && break
        label =
            labellen == 0 ? string(i - 1) :
            String(Char.(bytes(src, pos, labellen)))
        pos += labellen
        path = isempty(prefix) ? label : prefix * "." * label

        if kind == DM3_GROUP_ENTRY
            pos = _dm3_group!(h, arrays, src, pos, limit, little, path, depth + 1)
        elseif kind == DM3_DATA_ENTRY
            pos = _dm3_tag!(h, arrays, src, pos, limit, little, path)
        else
            break                       # not a kind we know: stop rather than guess
        end
    end
    return pos
end

"""Read one data tag: the `%%%%` marker, the encoded type, and the value."""
function _dm3_tag!(
    h::Header,
    arrays::Vector{Dm3Array},
    src::AbstractSource,
    pos::Int,
    limit::Int,
    little::Bool,
    path::String,
)
    pos + 12 > limit && return limit
    String(Char.(bytes(src, pos, 4))) == "%%%%" ||
        throw(CorruptFileError("DM3: missing %%%% marker for tag $path"))
    pos += 4
    datatype = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
    encoded = Int(bswap(_load_i32(bytes(src, pos + 4, 4), 1)))
    pos += 8

    if datatype == 1
        T = get(DM3_TYPES, encoded, nothing)
        T === nothing && return limit
        pos + sizeof(T) > limit && return limit
        h[path] = _dm3_scalar(src, pos, T, little)
        return pos + sizeof(T)

    elseif encoded == DM3_ARRAY && datatype == 3
        elemtype = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
        count = Int(bswap(_load_i32(bytes(src, pos + 4, 4), 1)))
        pos += 8
        T = get(DM3_TYPES, elemtype, nothing)
        (T === nothing || count < 0) && return limit
        nbytes = count * sizeof(T)
        pos + nbytes > limit && return limit
        istext = elemtype in (4, 9) && count <= DM3_INLINE_LIMIT &&
                 _dm3_looks_text(src, pos, count, T)
        if istext
            # DM has no string type: text is a UInt16 array, so decode it as such.
            h[path] = _dm3_text(src, pos, count)
        elseif count <= DM3_INLINE_LIMIT
            h[path] = [_dm3_scalar(src, pos + (k - 1) * sizeof(T), T, little) for k = 1:count]
        else
            h[path] = "<$count $(T) values>"
        end
        # Text is not a candidate image, or a long comment would outrank a small frame.
        istext || push!(arrays, Dm3Array(pos, T, count, path))
        return pos + nbytes

    elseif encoded == DM3_ARRAY && datatype > 3
        # An array of structs. Its layout is described, then the whole block is skipped:
        # nothing in it has been needed so far, and its element types vary per field.
        inner = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
        pos += 4
        inner == DM3_STRUCT || return limit
        pos += 4                                       # struct name length, unused
        nfields = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
        pos += 4
        (0 <= nfields <= 1024) || return limit
        widths = Int[]
        for _ = 1:nfields
            pos += 4                                   # field name length, unused
            ft = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
            pos += 4
            T = get(DM3_TYPES, ft, nothing)
            T === nothing && return limit
            push!(widths, sizeof(T))
        end
        count = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
        pos += 4
        h[path] = "<$count structs>"
        return min(pos + count * sum(widths), limit)

    elseif encoded == DM3_STRUCT
        pos += 4                                       # struct name length, unused
        nfields = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
        pos += 4
        (0 <= nfields <= 1024) || return limit
        types = DataType[]
        for _ = 1:nfields
            pos += 4                                   # field name length, unused
            ft = Int(bswap(_load_i32(bytes(src, pos, 4), 1)))
            pos += 4
            T = get(DM3_TYPES, ft, nothing)
            T === nothing && return limit
            push!(types, T)
        end
        vals = Any[]
        for T in types
            pos + sizeof(T) > limit && return limit
            push!(vals, _dm3_scalar(src, pos, T, little))
            pos += sizeof(T)
        end
        h[path] = vals
        return pos
    end
    return limit
end

@inline function _dm3_scalar(src::AbstractSource, pos::Int, ::Type{T}, little::Bool) where {T}
    raw = bytes(src, pos, sizeof(T))
    v = if sizeof(T) == 1
        reinterpret(T, raw[1])
    elseif sizeof(T) == 2
        reinterpret(T, little ? _load_u16(raw, 1) : bswap(_load_u16(raw, 1)))
    elseif sizeof(T) == 4
        reinterpret(T, little ? _load_u32(raw, 1) : bswap(_load_u32(raw, 1)))
    else
        reinterpret(T, little ? _load_u64(raw, 1) : bswap(_load_u64(raw, 1)))
    end
    return T <: AbstractFloat ? Float64(v) : Int(v)
end

"""Digital Micrograph stores text as a `UInt16` array; decide whether this one is text."""
function _dm3_looks_text(src::AbstractSource, pos::Int, count::Int, ::Type{T}) where {T}
    sizeof(T) == 2 || return false
    count == 0 && return false
    raw = bytes(src, pos, 2count)
    printable = 0
    for k = 1:count
        v = _load_u16(raw, 2k - 1)
        (v >= 0x20 && v < 0x7f) && (printable += 1)
    end
    return printable == count
end

_dm3_text(src::AbstractSource, pos::Int, count::Int) =
    String(Char.(UInt8[bytes(src, pos, 2count)[2k-1] for k = 1:count]))

"""
Work out the image shape.

Digital Micrograph records it as `Dimensions.0` and `Dimensions.1` beside the array, so prefer
those. Failing that, fall back to the `Active Size (pixels)` and `Binning` pair FabIO uses, and
finally to a square image if the count admits one.
"""
function _dm3_dims(h::Header, img::Dm3Array)
    parent = replace(img.path, r"\.[^.]*$" => "")
    d0 = _dm3_lookup(h, parent * ".Dimensions.0")
    d1 = _dm3_lookup(h, parent * ".Dimensions.1")
    if d0 isa Integer && d1 isa Integer && d0 > 0 && d1 > 0 && d0 * d1 == img.count
        return (Int(d0), Int(d1))
    end

    active = _dm3_leaf(h, "Active Size (pixels)")
    binning = _dm3_leaf(h, "Binning")
    if active !== nothing
        vals = active isa AbstractString ? tryparse.(Int, split(active)) : active
        if vals isa AbstractVector && length(vals) >= 2 && all(x -> x isa Integer && x > 0, vals[1:2])
            b1, b2 = 1, 1
            if binning isa AbstractVector && length(binning) >= 2
                b1, b2 = max(Int(binning[1]), 1), max(Int(binning[2]), 1)
            end
            cand = (Int(vals[1]) ÷ b1, Int(vals[2]) ÷ b2)
            prod(cand) == img.count && return cand
        end
    end

    side = isqrt(img.count)
    side * side == img.count && return (side, side)
    throw(CorruptFileError("DM3: cannot work out the shape of a $(img.count)-element image"))
end

_dm3_lookup(h::Header, key::AbstractString) = haskey(h, key) ? h[key] : nothing

"""Value of the first key whose last dotted component matches `leaf`."""
function _dm3_leaf(h::Header, leaf::AbstractString)
    for (k, v) in h
        (k == leaf || endswith(k, "." * leaf)) && return v
    end
    return nothing
end

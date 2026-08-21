"""
    TIFFLike{Flavour} <: ImageFormat

Baseline TIFF and the detector formats built on it: `TIFFLike{:plain}`, `TIFFLike{:pilatus}`
and `TIFFLike{:marccd}`.

All three share one reader. A Pilatus TIFF is an ordinary TIFF whose `ImageDescription` tag
holds a `# key value` text block; a MarCCD TIFF is an ordinary TIFF with a 3072-byte binary
header at file offset 1024. Only the metadata differs, so the flavour selects a header parser
and nothing else — which is what the `Flavour` type parameter is for, and what
[`refine`](@ref) resolves at detection time.

# Why there is no external TIFF dependency

Detector TIFFs are baseline: one sample per pixel, uncompressed, integer or float. Parsing the
IFD directly is a couple of hundred lines, keeps the core dependency-free, and — crucially —
lets an uncompressed image be described as a [`BinaryLayout`](@ref), so it memory-maps with no
copy like every other tier-1 format. Handing the file to an image-oriented library instead
would convert detector counts into fixed-point display types and forfeit that. FabIO reaches
the same conclusion, shipping its own `TiffIO` rather than depending on one.

Compressed TIFFs and BigTIFF are not handled yet and raise a clear error.

# Both tiers, in one format

A single-strip image (or one whose strips happen to be contiguous) is tier 1: the scan hands
back a layout and the core does the rest. A genuinely multi-strip image cannot be expressed as
one contiguous encoded blob, so this format overrides [`readframe`](@ref) and gathers the
strips itself — the first tier-2 reader in the package.
"""
struct TIFFLike{Flavour} <: ImageFormat end

const TIFF_LE = UInt8[0x49, 0x49, 0x2A, 0x00]
const TIFF_BE = UInt8[0x4D, 0x4D, 0x00, 0x2A]

# The tags this reader cares about.
const TIFF_IMAGE_WIDTH = 256
const TIFF_IMAGE_LENGTH = 257
const TIFF_BITS_PER_SAMPLE = 258
const TIFF_COMPRESSION = 259
const TIFF_IMAGE_DESCRIPTION = 270
const TIFF_STRIP_OFFSETS = 273
const TIFF_SAMPLES_PER_PIXEL = 277
const TIFF_ROWS_PER_STRIP = 278
const TIFF_STRIP_BYTE_COUNTS = 279
const TIFF_TILE_OFFSETS = 324
const TIFF_SAMPLE_FORMAT = 339

"""Byte width of each TIFF field type, indexed by the type code."""
const TIFF_TYPE_SIZES =
    Dict(1 => 1, 2 => 1, 3 => 2, 4 => 4, 5 => 8, 6 => 1, 7 => 1, 8 => 2, 9 => 4, 10 => 8, 11 => 4, 12 => 8)

"""One image file directory: its tags, and where the next one lives."""
struct TiffIFD
    tags::Dict{Int,Vector{Int64}}
    description::String
end

"""What a multi-strip frame needs, since it cannot be described as one `BinaryLayout`."""
struct TiffStrips{T}
    offsets::Vector{Int64}
    counts::Vector{Int64}
    dims::Dims{2}
    byteorder::ByteOrder
end

# -------------------------------------------------------------------- primitive reads

@inline _tiff_u16(src, off, be) = be ? bswap(_load_u16(bytes(src, off, 2), 1)) : _load_u16(bytes(src, off, 2), 1)
@inline _tiff_u32(src, off, be) = be ? bswap(_load_u32(bytes(src, off, 4), 1)) : _load_u32(bytes(src, off, 4), 1)

function _tiff_values(src::AbstractSource, be::Bool, type::Int, count::Int, valoff::Int)
    sz = get(TIFF_TYPE_SIZES, type, 0)
    sz == 0 && return Int64[]
    # `valoff` is already resolved by the caller: inline for <= 4 bytes, dereferenced otherwise.
    base = valoff
    out = Vector{Int64}(undef, count)
    for i = 0:(count-1)
        o = base + i * sz
        out[i+1] = if sz == 1
            Int64(_byteat(src, o))
        elseif sz == 2
            Int64(_tiff_u16(src, o, be))
        elseif sz == 4
            Int64(_tiff_u32(src, o, be))
        else
            Int64(_tiff_u32(src, o, be))     # rationals: keep the numerator
        end
    end
    return out
end

function _tiff_read_ifd(src::AbstractSource, be::Bool, ifdoff::Int)
    n = Int(_tiff_u16(src, ifdoff, be))
    tags = Dict{Int,Vector{Int64}}()
    description = ""
    for e = 0:(n-1)
        entry = ifdoff + 2 + 12 * e
        tag = Int(_tiff_u16(src, entry, be))
        type = Int(_tiff_u16(src, entry + 2, be))
        count = Int(_tiff_u32(src, entry + 4, be))
        sz = get(TIFF_TYPE_SIZES, type, 0)
        sz == 0 && continue
        total = sz * count
        valoff = total <= 4 ? entry + 8 : Int(_tiff_u32(src, entry + 8, be))
        if tag == TIFF_IMAGE_DESCRIPTION && type == 2
            stop = min(valoff + count, filesize(src))
            description = String(Char.(bytes(src, valoff, stop - valoff)))
        else
            count > 1_000_000 && continue        # refuse absurd tag counts
            tags[tag] = _tiff_values(src, be, type, count, valoff)
        end
    end
    nextoff = Int(_tiff_u32(src, ifdoff + 2 + 12 * n, be))
    return TiffIFD(tags, description), nextoff
end

_tag(ifd::TiffIFD, tag::Int, default) =
    haskey(ifd.tags, tag) && !isempty(ifd.tags[tag]) ? Int(ifd.tags[tag][1]) : default

function _tiff_eltype(bits::Int, format::Int)
    if format == 3
        bits == 32 && return Float32
        bits == 64 && return Float64
    elseif format == 2
        bits == 8 && return Int8
        bits == 16 && return Int16
        bits == 32 && return Int32
        bits == 64 && return Int64
    else
        bits == 8 && return UInt8
        bits == 16 && return UInt16
        bits == 32 && return UInt32
        bits == 64 && return UInt64
    end
    throw(UnsupportedFormatError("TIFF: no Julia type for $bits bits, sample format $format"))
end

# --------------------------------------------------------------------------- scanning

function scan(fmt::TIFFLike, src::AbstractSource)
    filesize(src) < 8 && throw(TruncatedFileError("TIFF: file is too short for a header"))
    head = bytes(src, 0, 4)
    be = if @views head[1:4] == TIFF_BE
        true
    elseif @views head[1:4] == TIFF_LE
        false
    elseif head[1] == 0x49 && head[2] == 0x49 && head[3] == 0x2B
        throw(UnsupportedFormatError("BigTIFF is not supported yet"))
    elseif head[1] == 0x4D && head[2] == 0x4D && head[3] == 0x00 && head[4] == 0x2B
        throw(UnsupportedFormatError("BigTIFF is not supported yet"))
    else
        throw(CorruptFileError("TIFF: bad byte-order mark or magic"))
    end
    byteorder = be ? BigEndian() : LittleEndian()

    specs = FrameSpec[]
    ifdoff = Int(_tiff_u32(src, 4, be))
    seen = Set{Int}()

    while ifdoff != 0 && ifdoff < filesize(src)
        ifdoff in seen && throw(CorruptFileError("TIFF: IFD chain loops at byte $ifdoff"))
        push!(seen, ifdoff)
        ifd, nextoff = _tiff_read_ifd(src, be, ifdoff)

        width = _tag(ifd, TIFF_IMAGE_WIDTH, 0)
        height = _tag(ifd, TIFF_IMAGE_LENGTH, 0)
        (width > 0 && height > 0) ||
            throw(CorruptFileError("TIFF: missing or zero image dimensions"))

        compression = _tag(ifd, TIFF_COMPRESSION, 1)
        compression == 1 || throw(
            UnsupportedFormatError(
                "TIFF compression code $compression is not supported yet (only uncompressed)",
            ),
        )
        spp = _tag(ifd, TIFF_SAMPLES_PER_PIXEL, 1)
        spp == 1 || throw(
            UnsupportedFormatError("TIFF: $spp samples per pixel; detector images have one"),
        )

        T = _tiff_eltype(_tag(ifd, TIFF_BITS_PER_SAMPLE, 8), _tag(ifd, TIFF_SAMPLE_FORMAT, 1))
        offsets = get(ifd.tags, TIFF_STRIP_OFFSETS, Int64[])
        if isempty(offsets)
            haskey(ifd.tags, TIFF_TILE_OFFSETS) && throw(
                UnsupportedFormatError("tiled TIFF is not supported yet (only stripped images)"),
            )
            throw(CorruptFileError("TIFF: no StripOffsets"))
        end
        counts = get(ifd.tags, TIFF_STRIP_BYTE_COUNTS, Int64[])
        if length(counts) != length(offsets)
            rows = _tag(ifd, TIFF_ROWS_PER_STRIP, height)
            counts = [Int64(min(rows, height - (i - 1) * rows) * width * sizeof(T)) for i in eachindex(offsets)]
        end

        h = Header()
        h["ImageWidth"] = width
        h["ImageLength"] = height
        h["BitsPerSample"] = _tag(ifd, TIFF_BITS_PER_SAMPLE, 8)
        h["SampleFormat"] = _tag(ifd, TIFF_SAMPLE_FORMAT, 1)
        h["Compression"] = compression
        h["ByteOrder"] = be ? "HighByteFirst" : "LowByteFirst"
        h["NumberOfStrips"] = length(offsets)
        isempty(ifd.description) || (h["ImageDescription"] = ifd.description)
        _tiff_flavour_header!(fmt, h, src, ifd, (width, height))

        if _tiff_contiguous(offsets, counts)
            layout = BinaryLayout{T}(
                offsets[1],
                sum(counts),
                (width, height);
                byteorder = byteorder,
                codec = RawBlob(),
            )
            push!(specs, FrameSpec(h, layout))
        else
            push!(specs, FrameSpec(h, TiffStrips{T}(offsets, counts, (width, height), byteorder)))
        end

        ifdoff = nextoff
    end

    isempty(specs) && throw(CorruptFileError("TIFF: no image file directory found"))
    return Header(), specs
end

"""Strips are contiguous when each starts exactly where the previous one ended."""
function _tiff_contiguous(offsets::Vector{Int64}, counts::Vector{Int64})
    length(offsets) == 1 && return true
    for i = 2:length(offsets)
        offsets[i] == offsets[i-1] + counts[i-1] || return false
    end
    return true
end

# A `FrameSpec` carries whatever descriptor its format needs; for a multi-strip TIFF that is a
# `TiffStrips` rather than a `BinaryLayout`, which is exactly the distinction the two tiers turn
# on. These two methods let the core report the element type and shape without knowing which.
Base.eltype(::FrameSpec{TiffStrips{T}}) where {T} = T
framedims(s::FrameSpec{<:TiffStrips}) = s.layout.dims

# ------------------------------------------------------------------------- tier 2 read

"""
Gather a multi-strip TIFF frame.

Contiguous images never reach here — they are ordinary tier-1 layouts. This is the case a
`BinaryLayout` genuinely cannot describe, since the pixels are several disjoint runs of bytes.
"""
function readframe(f::ImageFile{<:TIFFLike}, i::Int)
    spec = f.frames[i]
    spec.layout isa BinaryLayout && return readframe_layout(f, i)
    st = spec.layout
    st isa TiffStrips ||
        throw(CorruptFileError("TIFF: frame $i has neither a layout nor a strip table"))
    return ImageFrame(
        _tiff_gather(f.source, st),
        _frameheader(f, spec),
        fileindex = i,
        seriesindex = i,
        source = f.path,
    )
end

function _tiff_gather(src::AbstractSource, st::TiffStrips{T}) where {T}
    out = Array{T}(undef, st.dims)
    dest = 1
    total = length(out) * sizeof(T)
    written = 0
    GC.@preserve out begin
        p = Ptr{UInt8}(pointer(out))
        for (off, cnt) in zip(st.offsets, st.counts)
            n = Int(min(cnt, total - written))
            n <= 0 && break
            raw = bytes(src, off, n)
            GC.@preserve raw unsafe_copyto!(p + written, pointer(raw), n)
            written += n
        end
    end
    written == total ||
        throw(TruncatedFileError("TIFF: strips supplied $written of $total bytes"))
    _fixbyteorder!(out, st.byteorder)
    return out
end

# ------------------------------------------------------------------- flavour detection

"""
Resolve a plain TIFF to a detector flavour.

FabIO puts the composite string `"marccd/tif"` in its magic table and special-cases it inside
the detection function; here the format family resolves itself, which is what [`refine`](@ref)
is for. Pilatus is usually caught earlier by its more specific magic (its first IFD sits at
byte 0x82), so this is the fallback path for both.
"""
function refine(
    ::TIFFLike{:plain},
    ::AbstractVector{UInt8},
    path::Union{Nothing,AbstractString},
    src::AbstractSource,
)
    if path !== nothing
        ext = lowercase(last(splitext(first(stripcompression(path)))))
        ext == ".mccd" && return TIFFLike{:marccd}()
    end
    _tiff_looks_marccd(src) && return TIFFLike{:marccd}()
    _tiff_looks_pilatus(src) && return TIFFLike{:pilatus}()
    return TIFFLike{:plain}()
end

"""A MarCCD header carries the ASCII name "MMX" at offset 1028, just after its type word."""
function _tiff_looks_marccd(src::AbstractSource)
    filesize(src) < 1024 + 3072 && return false
    name = bytes(src, 1028, 4)
    return name[1] == UInt8('M') && name[2] == UInt8('M') && name[3] == UInt8('X')
end

"""Pilatus writes its header as `# key value` text into the ImageDescription tag."""
function _tiff_looks_pilatus(src::AbstractSource)
    window = min(filesize(src), 65536)
    window < 16 && return false
    hay = bytes(src, 0, window)
    needle = Vector{UInt8}(codeunits("# Pixel_size"))
    m = length(needle)
    @inbounds for i = 1:(window-m+1)
        ok = true
        for j = 1:m
            if hay[i+j-1] != needle[j]
                ok = false
                break
            end
        end
        ok && return true
    end
    return false
end

# ------------------------------------------------------------------- flavour metadata

_tiff_flavour_header!(::TIFFLike, ::Header, ::AbstractSource, ::TiffIFD, ::Dims{2}) = nothing

"""
Parse the Pilatus header: `# key value` lines in the ImageDescription tag.

The separator between key and value is the first comma, colon, equals sign or run of
whitespace, matching FabIO's regular expression.
"""
function _tiff_flavour_header!(
    ::TIFFLike{:pilatus},
    h::Header,
    ::AbstractSource,
    ifd::TiffIFD,
    ::Dims{2},
)
    isempty(ifd.description) && return nothing
    for raw in split(ifd.description, '\n')
        line = strip(raw, ['\0', ' ', '\t', '\r'])
        startswith(line, "# ") || continue
        body = strip(line[3:end])
        isempty(body) && continue
        m = match(r"^(.*?)\s*[,:=\s]\s*(.*)$", body)
        m === nothing && continue
        key = String(strip(m.captures[1]))
        isempty(key) && continue
        h[key] = String(strip(m.captures[2]))
    end
    return nothing
end

"""
Fields of the 3072-byte MarCCD header, at file offset 1024.

Only fields sitting at the head of one of the header's documented fixed-size sections are
read — section starts are 0, 256, 384, 640, 768 and 896 — because those offsets are anchored
by the section boundaries rather than by a running count of intervening fields. The scale is
the multiplier to reach physical units.
"""
const MARCCD_FIELDS = (
    (80, "nfast", 1.0),
    (84, "nslow", 1.0),
    (88, "depth", 1.0),
    (100, "data_type", 1.0),
    (116, "origin", 1.0),
    (120, "orientation", 1.0),
    (132, "over_8_bits", 1.0),
    (136, "over_16_bits", 1.0),
    (640, "xtal_to_detector", 1e-3),        # mm
    # The C header calls these pixels, but real files store millimetres: dividing by
    # pixelsize puts the beam at the centre of the detector, which pixels would not.
    (644, "beam_x", 1e-3),
    (648, "beam_y", 1e-3),
    (652, "integration_time", 1e-3),        # s
    (656, "exposure_time", 1e-3),           # s
    (660, "readout_time", 1e-3),            # s
    (768, "detector_type", 1.0),
    (772, "pixelsize_x", 1e-6),             # nm -> mm
    (776, "pixelsize_y", 1e-6),             # nm -> mm
    (896, "source_type", 1.0),
    (908, "source_wavelength", 1e-5),       # fm -> Å
)

const MARCCD_HEADER_OFFSET = 1024

function _tiff_flavour_header!(
    ::TIFFLike{:marccd},
    h::Header,
    src::AbstractSource,
    ::TiffIFD,
    dims::Dims{2},
)
    filesize(src) < MARCCD_HEADER_OFFSET + 3072 && return nothing
    raw = bytes(src, MARCCD_HEADER_OFFSET, 3072)
    # FabIO reads this header little-endian unconditionally and so do we; every MarCCD file
    # seen in the wild is written that way. The dimension cross-check below would catch a
    # big-endian one, since the values would come out absurd.
    word(off) = _load_i32(raw, off + 1)
    for (off, name, scale) in MARCCD_FIELDS
        v = word(off)
        h[name] = scale == 1.0 ? Int(v) : Int(v) * scale
    end
    # Self-check: the MarCCD header repeats the image dimensions, so if the offsets above are
    # right these must agree with the TIFF tags. Warn rather than fail — the pixels are read
    # through the TIFF path either way, so only the metadata is in doubt.
    nfast, nslow = Int(word(80)), Int(word(84))
    if (nfast, nslow) != dims && nfast != 0 && nslow != 0
        @warn "MarCCD header dimensions disagree with the TIFF tags; treat its metadata with suspicion" marccd =
            (nfast, nslow) tiff = dims
    end
    return nothing
end

# ------------------------------------------------------------------------------ writing

"""
    writetiff(path, A; kwargs...)
    writetiff(path, arrays; kwargs...)

Write a baseline TIFF: uncompressed, one sample per pixel, one IFD per array.

Keyword arguments:

- `description` — text for the `ImageDescription` tag, which is where a Pilatus header lives
- `bigendian` — write `MM` byte order instead of `II`
- `rowsperstrip` — split each image into strips; zero writes one strip
- `stripgap` — bytes of padding between strips, which makes them non-contiguous and so
  forces the reader down its multi-strip path
- `mindataoffset` — pad so the first image's pixels start no earlier than this, the layout
  MarCCD uses to leave room for its 3072-byte header at offset 1024
"""
function writetiff(path::AbstractString, A::AbstractArray{<:Any,2}; kwargs...)
    return writetiff(path, [A]; kwargs...)
end

function writetiff(
    path::AbstractString,
    arrays::AbstractVector{<:AbstractArray{T,2}};
    description::AbstractString = "",
    bigendian::Bool = false,
    rowsperstrip::Int = 0,
    stripgap::Int = 0,
    mindataoffset::Int = 0,
) where {T}
    isempty(arrays) && throw(ArgumentError("writetiff needs at least one image"))
    bits = 8 * sizeof(T)
    fmt = T <: AbstractFloat ? 3 : (T <: Signed ? 2 : 1)
    swap = bigendian != (NativeByteOrder === BigEndian)
    u16(v) = (x = UInt16(v); swap ? bswap(x) : x)
    u32(v) = (x = UInt32(v); swap ? bswap(x) : x)
    desc = Vector{UInt8}(codeunits(description))

    tags = Int[
        TIFF_IMAGE_WIDTH, TIFF_IMAGE_LENGTH, TIFF_BITS_PER_SAMPLE, TIFF_COMPRESSION,
        262, TIFF_STRIP_OFFSETS, TIFF_SAMPLES_PER_PIXEL, TIFF_ROWS_PER_STRIP,
        TIFF_STRIP_BYTE_COUNTS, TIFF_SAMPLE_FORMAT,
    ]
    isempty(desc) || push!(tags, TIFF_IMAGE_DESCRIPTION)
    sort!(tags)                                     # TIFF requires ascending tag order

    # Pass one: lay the file out.
    nframes = length(arrays)
    plans = NamedTuple[]
    pos = 8
    for (fi, A) in pairs(arrays)
        width, height = size(A)
        rows = rowsperstrip <= 0 ? height : rowsperstrip
        nstrips = cld(height, rows)
        stripbytes =
            [Int(min(rows, height - (i - 1) * rows)) * width * sizeof(T) for i = 1:nstrips]
        ifdoff = pos
        pos += 2 + 12 * length(tags) + 4
        descoff = pos
        pos += length(desc)
        offtableoff = pos
        pos += nstrips > 1 ? 4 * nstrips : 0
        cnttableoff = pos
        pos += nstrips > 1 ? 4 * nstrips : 0
        fi == 1 && (pos = max(pos, mindataoffset))
        stripoffsets = Int[]
        for i = 1:nstrips
            push!(stripoffsets, pos)
            pos += stripbytes[i] + (i < nstrips ? stripgap : 0)
        end
        push!(
            plans,
            (; width, height, rows, nstrips, stripbytes, stripoffsets, ifdoff, descoff,
             offtableoff, cnttableoff),
        )
    end

    # Pass two: write it.
    io = IOBuffer()
    write(io, bigendian ? TIFF_BE : TIFF_LE)
    write(io, u32(plans[1].ifdoff))
    for (fi, A) in pairs(arrays)
        pl = plans[fi]
        @assert position(io) == pl.ifdoff
        write(io, u16(length(tags)))
        for tag in tags
            type, count, value = if tag == TIFF_IMAGE_WIDTH
                (3, 1, pl.width)
            elseif tag == TIFF_IMAGE_LENGTH
                (3, 1, pl.height)
            elseif tag == TIFF_BITS_PER_SAMPLE
                (3, 1, bits)
            elseif tag == TIFF_COMPRESSION || tag == 262 || tag == TIFF_SAMPLES_PER_PIXEL
                (3, 1, 1)
            elseif tag == TIFF_ROWS_PER_STRIP
                (3, 1, pl.rows)
            elseif tag == TIFF_SAMPLE_FORMAT
                (3, 1, fmt)
            elseif tag == TIFF_IMAGE_DESCRIPTION
                (2, length(desc), pl.descoff)
            elseif tag == TIFF_STRIP_OFFSETS
                (4, pl.nstrips, pl.nstrips == 1 ? pl.stripoffsets[1] : pl.offtableoff)
            else
                (4, pl.nstrips, pl.nstrips == 1 ? pl.stripbytes[1] : pl.cnttableoff)
            end
            write(io, u16(tag), u16(type), u32(count))
            if type == 3 && count == 1
                write(io, u16(value), u16(0))   # a SHORT is left-justified in its four bytes
            else
                write(io, u32(value))
            end
        end
        write(io, u32(fi < nframes ? plans[fi+1].ifdoff : 0))
        isempty(desc) || write(io, desc)
        if pl.nstrips > 1
            for v in pl.stripoffsets
                write(io, u32(v))
            end
            for v in pl.stripbytes
                write(io, u32(v))
            end
        end
        payload = swap ? reinterpret(UInt8, bswap.(vec(collect(A)))) : encode(RawBlob(), A)
        done = 0
        for i = 1:pl.nstrips
            while position(io) < pl.stripoffsets[i]
                write(io, 0x00)                  # padding: mindataoffset or a strip gap
            end
            write(io, @view payload[(done+1):(done+pl.stripbytes[i])])
            done += pl.stripbytes[i]
        end
    end
    Base.open(path, "w") do f
        Base.write(f, take!(io))
    end
    return path
end


"""
    writemarccd(path, A, header = Header())

Write a MarCCD file: a baseline TIFF whose pixels begin at 4096, with the 3072-byte binary
header spliced in at offset 1024.

Values for the fields in [`MARCCD_FIELDS`](@ref) are taken from `header` when present, in the
same physical units the reader reports, and written back at the scale the format stores. Fields
absent from `header` are left zero, which is what a MarCCD header uses for "not recorded".
`nfast`, `nslow` and `depth` always come from the array itself, so they cannot disagree with
the TIFF tags.

MarCCD stores unsigned 16-bit counts; [`coerce`](@ref) converts anything else.
"""
function writemarccd(path::AbstractString, A::AbstractArray{<:Any,2}, header::Header = Header())
    B = coerce(TIFFLike{:marccd}(), A)
    writetiff(path, B; mindataoffset = MARCCD_HEADER_OFFSET + 3072)

    hdr = zeros(UInt8, 3072)
    put32(off::Int, v::Integer) =
        (hdr[(off+1):(off+4)] = reinterpret(UInt8, [htol(Int32(v))]); nothing)
    # header_name, the "MMX" tag `refine` looks for.
    hdr[5:7] = Vector{UInt8}(codeunits("MMX"))
    put32(0, 1)                                    # header_type
    put32(20, 1)                                   # header_major_version
    put32(36, 3072)                                # header_size
    put32(76, 1)                                   # nheaders
    put32(80, size(B, 1))                          # nfast
    put32(84, size(B, 2))                          # nslow
    put32(88, sizeof(eltype(B)))                   # depth
    put32(92, size(B, 1))                          # record_length
    put32(96, 8 * sizeof(eltype(B)))               # signif_bits

    for (off, name, scale) in MARCCD_FIELDS
        name in ("nfast", "nslow", "depth") && continue
        v = getci(header, name)
        v === nothing && continue
        num = _convert_header(Float64, v)
        num === nothing && continue
        put32(off, round(Int, num / scale))
    end

    raw = read(path)
    raw[(MARCCD_HEADER_OFFSET+1):(MARCCD_HEADER_OFFSET+3072)] = hdr
    Base.open(path, "w") do f
        Base.write(f, raw)
    end
    return path
end

"MarCCD stores unsigned 16-bit counts."
function coerce(::TIFFLike{:marccd}, A::AbstractArray{T,2}) where {T}
    T === UInt16 && return A
    B = T <: Integer ? A : (@info "MarCCD stores integers; rounding"; round.(A))
    any(x -> x < 0 || x > 65535, B) &&
        @warn "MarCCD is 16-bit unsigned; values outside 0:65535 will wrap"
    # `%` is the modular conversion that implements the wrap the warning describes, but it is
    # defined between integers: rounding a float array leaves it a float array, so it has to
    # become an integer one first.
    C = B isa AbstractArray{<:Integer} ? B : convert(Array{Int64}, B)
    return convert(Array{UInt16}, C .% UInt16)
end

"""Generic write entry point. A TIFF holds one IFD per frame. See [`writeformat`](@ref)."""
writeformat(::TIFFLike{:plain}, path::AbstractString, arrays::AbstractVector, ::AbstractVector; kwargs...) =
    writetiff(path, arrays; kwargs...)

"""Generic write entry point. A MarCCD file holds a single image. See [`writeformat`](@ref)."""
writeformat(fmt::TIFFLike{:marccd}, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone(writemarccd, fmt, path, arrays, headers; kwargs...)

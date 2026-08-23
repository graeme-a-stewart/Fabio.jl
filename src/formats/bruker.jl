"""
    Bruker{Version} <: ImageFormat

Bruker area-detector frames (`.sfrm`): `Bruker{86}` and `Bruker{100}`. Both share the header
format and differ only in how the pixels are stored, so [`refine`](@ref) reads the `FORMAT` key
and picks the version at detection time.

# On-disk structure

    80-character `KEY:value` lines, packed into 512-byte blocks. `HDRBLKS` — which is
    guaranteed to appear within the first five blocks — gives the total header size in
    blocks, so the pixels start at `512 * HDRBLKS`.

    <pixels>      NROWS x NCOLS values of NPIXELB bytes each, little-endian
    <overflows>   NOVERFL records of 16 ASCII characters: 9 of intensity, 7 of position

A key that appears on several lines has its values joined with newlines, matching FabIO.

`NPIXELB` is usually 1 or 2 bytes, so counts that do not fit are carried in the overflow
records and patched in afterwards — the same shape of problem as mar345's overflow table, and
handled the same way, by giving the codec the table the scan already read.

`FORMAT:100` keeps its counts in a narrow base image plus up to three padded correction
tables; see [`Bruker100Blob`](@ref).
"""
struct Bruker{Version} <: ImageFormat end

const BRUKER_LINE = 80
const BRUKER_BLOCK = 512
const BRUKER_MIN_BLOCKS = 5

"""
    BrukerBlob(bytesperpixel, overflow_index, overflow_value, slope, offset)

Bruker's pixel encoding: narrow unsigned integers, a table of wider values to patch in, and an
optional affine rescale from the `LINEAR` header key.

Defined next to its format rather than alongside the shared codecs, because nothing else uses
it — a format is free to introduce its own codec without touching the core.
"""
struct BrukerBlob <: AbstractDataCodec
    bytesperpixel::Int
    overflow_index::Vector{Int}     # 0-based flat positions, as stored
    overflow_value::Vector{UInt32}
    slope::Float64
    offset::Float64
end

const BRUKER_BPP_TYPES = Dict(1 => UInt8, 2 => UInt16, 4 => UInt32)

function decode(c::BrukerBlob, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    S = get(BRUKER_BPP_TYPES, c.bytesperpixel, nothing)
    S === nothing &&
        throw(UnsupportedFormatError("Bruker: NPIXELB=$(c.bytesperpixel) is not 1, 2 or 4"))
    return _bruker_decode(c, raw, T, dims, S)
end

function _bruker_decode(
    c::BrukerBlob,
    raw::AbstractVector{UInt8},
    ::Type{T},
    dims::Dims{2},
    ::Type{S},
) where {T,S}
    stored = decode(RawBlob(), raw, S, dims)      # Bruker pixels are always little-endian
    isnative(LittleEndian()) || _fixbyteorder!(stored, LittleEndian())
    out = Array{T}(undef, dims)
    n = length(out)
    @inbounds for i = 1:n
        out[i] = _bruker_value(T, stored[i], c)
    end
    @inbounds for k in eachindex(c.overflow_index)
        j = c.overflow_index[k] + 1               # stored 0-based
        (j >= 1 && j <= n) || continue
        out[j] = _bruker_value(T, c.overflow_value[k], c)
    end
    return out
end

@inline function _bruker_value(::Type{T}, v, c::BrukerBlob) where {T<:AbstractFloat}
    return T(Float64(v) * c.slope + c.offset)
end
@inline _bruker_value(::Type{T}, v, ::BrukerBlob) where {T<:Integer} = T(v)

function scan(fmt::Bruker, src::AbstractSource)
    n = filesize(src)
    n < BRUKER_MIN_BLOCKS * BRUKER_BLOCK &&
        throw(TruncatedFileError("Bruker: file is shorter than the minimum five header blocks"))

    h = Header()
    _bruker_parse!(h, src, 0, BRUKER_MIN_BLOCKS * BRUKER_BLOCK)
    hdrblks = getheader(h, "HDRBLKS", Int, BRUKER_MIN_BLOCKS)
    hdrblks < BRUKER_MIN_BLOCKS &&
        throw(CorruptFileError("Bruker: HDRBLKS is $hdrblks, fewer than the five always present"))
    headerbytes = hdrblks * BRUKER_BLOCK
    headerbytes > n &&
        throw(TruncatedFileError("Bruker: HDRBLKS implies a $headerbytes-byte header, file holds $n"))
    if hdrblks > BRUKER_MIN_BLOCKS
        _bruker_parse!(h, src, BRUKER_MIN_BLOCKS * BRUKER_BLOCK, headerbytes)
    end
    h["HDRBLKS"] = hdrblks
    h["datastart"] = headerbytes

    version = getheader(h, "FORMAT", Int, 86)
    version in (86, 100) ||
        throw(UnsupportedFormatError("Bruker FORMAT:$version is not supported"))

    rows = _bruker_int(h, "NROWS")
    cols = _bruker_int(h, "NCOLS")
    (rows > 0 && cols > 0) ||
        throw(CorruptFileError("Bruker: missing or zero NROWS/NCOLS ($rows, $cols)"))
    dims = (cols, rows)          # NCOLS is the fast axis

    npixelb = _bruker_int(h, "NPIXELB")
    S = get(BRUKER_BPP_TYPES, npixelb, nothing)
    S === nothing &&
        throw(UnsupportedFormatError("Bruker: NPIXELB=$npixelb is not 1, 2 or 4"))

    databytes = rows * cols * npixelb
    headerbytes + databytes > n &&
        throw(TruncatedFileError("Bruker: needs $databytes bytes of pixels, file holds $n"))

    if version == 100
        codec = _bruker100_codec(h, src, headerbytes + databytes, npixelb, n)
        layout = BinaryLayout{Int32}(
            headerbytes, databytes, dims; byteorder = LittleEndian(), codec = codec)
        return Header(), FrameSpec[FrameSpec(h, layout)]
    end

    nover = _bruker_int(h, "NOVERFL", 0)
    oidx, oval = _bruker_overflow(src, headerbytes + databytes, nover, n)

    slope, offset = _bruker_linear(h)
    T = if slope != 1.0 || offset != 0.0
        Float32
    elseif isempty(oidx)
        S
    else
        UInt32
    end

    codec = BrukerBlob(npixelb, oidx, oval, slope, offset)
    layout = BinaryLayout{T}(
        headerbytes,
        databytes,
        dims;
        byteorder = LittleEndian(),
        codec = codec,
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""
    refine(::Bruker{86}, head, path, src)

Both versions open with the same `FORMAT :` line, so the version is read from the header rather
than guessed from a magic number.
"""
function refine(
    ::Bruker{86},
    ::AbstractVector{UInt8},
    ::Union{Nothing,AbstractString},
    src::AbstractSource,
)
    filesize(src) < BRUKER_MIN_BLOCKS * BRUKER_BLOCK && return Bruker{86}()
    h = Header()
    _bruker_parse!(h, src, 0, BRUKER_MIN_BLOCKS * BRUKER_BLOCK)
    return getheader(h, "FORMAT", Int, 86) == 100 ? Bruker{100}() : Bruker{86}()
end

# The codec has already put the values in host order.
_fixbyteorder!(A, ::ByteOrder, ::BrukerBlob) = A

"""Parse 80-character `KEY:value` lines from the byte range `[from, to)`."""
function _bruker_parse!(h::Header, src::AbstractSource, from::Int, to::Int)
    text = String(Char.(bytes(src, from, to - from)))
    for i = 1:BRUKER_LINE:(length(text)-BRUKER_LINE+1)
        line = text[i:(i+BRUKER_LINE-1)]
        j = findfirst(':', line)
        (j === nothing || j == 1) && continue
        key = String(strip(line[1:prevind(line, j)]))
        val = String(strip(line[nextind(line, j):end], ['\0', ' ', '\t', '\r', '\n']))
        isempty(key) && continue
        # A key spread over several lines accumulates, as in FabIO.
        h[key] = haskey(h, key) ? string(h[key], "\n", val) : val
    end
    return h
end

"""First whitespace-separated token of a header value, as an integer."""
function _bruker_int(h::Header, key::AbstractString, default::Union{Int,Nothing} = nothing)
    v = getci(h, key)
    if v === nothing
        default === nothing && throw(CorruptFileError("Bruker: missing header key $key"))
        return default
    end
    tok = first(split(strip(String(v))), )
    parsed = tryparse(Int, tok)
    if parsed === nothing
        default === nothing &&
            throw(CorruptFileError("Bruker: header key $key = $(repr(String(v))) is not an integer"))
        return default
    end
    return parsed
end

"""`LINEAR` holds a slope and an offset; an identity pair means no rescaling."""
function _bruker_linear(h::Header)
    v = getci(h, "LINEAR")
    v === nothing && return (1.0, 0.0)
    parts = split(strip(String(v)))
    length(parts) < 2 && return (1.0, 0.0)
    slope = tryparse(Float64, parts[1])
    offset = tryparse(Float64, parts[2])
    (slope === nothing || offset === nothing) && return (1.0, 0.0)
    return (slope, offset)
end

"""
Read the overflow table: `NOVERFL` records of 16 ASCII characters, nine of intensity followed
by seven of flat position.
"""
function _bruker_overflow(src::AbstractSource, offset::Int, nover::Int, filesz::Int)
    nover <= 0 && return (Int[], UInt32[])
    need = 16 * nover
    offset + need > filesz && throw(
        TruncatedFileError("Bruker: $nover overflow records need $need bytes past $offset"),
    )
    text = String(Char.(bytes(src, offset, need)))
    idx = Int[]
    val = UInt32[]
    for k = 0:(nover-1)
        rec = text[(16k+1):(16k+16)]
        intensity = tryparse(Int, strip(rec[1:9]))
        position = tryparse(Int, strip(rec[10:16]))
        (intensity === nothing || position === nothing) && continue
        push!(idx, position)
        push!(val, UInt32(max(intensity, 0)))
    end
    return idx, val
end

"""
    writebruker(path, A, header = Header(); hdrblks = 5, overflow = ())

Minimal Bruker `FORMAT:86` writer for the test suite. `overflow` is a collection of
`(position, intensity)` pairs written as 16-character records after the pixels; positions are
0-based flat indices, as the format stores them.
"""
function writebruker(
    path::AbstractString,
    A::AbstractArray{T,2},
    header::Header = Header();
    hdrblks::Int = 5,
    overflow = (),
) where {T}
    npixelb = sizeof(T)
    haskey(BRUKER_BPP_TYPES, npixelb) ||
        throw(UnsupportedFormatError("Bruker cannot store $T"))
    cols, rows = size(A)
    lines = String[]
    push!(lines, _bruker_line("FORMAT", "86"))
    push!(lines, _bruker_line("VERSION", "17"))
    push!(lines, _bruker_line("HDRBLKS", string(hdrblks)))
    push!(lines, _bruker_line("NROWS", string(rows)))
    push!(lines, _bruker_line("NCOLS", string(cols)))
    push!(lines, _bruker_line("NPIXELB", string(npixelb)))
    push!(lines, _bruker_line("NOVERFL", string(length(overflow))))
    for (k, v) in striplayoutkeys(Bruker{86}(), header)
        push!(lines, _bruker_line(k, string(v)))
    end
    body = join(lines)
    total = hdrblks * BRUKER_BLOCK
    length(body) <= total ||
        throw(ArgumentError("Bruker header needs $(length(body)) bytes, more than $total"))
    Base.open(path, "w") do f
        Base.write(f, codeunits(body))
        Base.write(f, codeunits(" "^(total - length(body))))
        Base.write(f, encode(RawBlob(), A))
        for (pos, intensity) in overflow
            Base.write(f, codeunits(lpad(string(intensity), 9) * lpad(string(pos), 7)))
        end
    end
    return path
end

_bruker_line(key::AbstractString, value::AbstractString) =
    rpad(rpad(uppercase(key), 7) * ":" * value, BRUKER_LINE)

# ------------------------------------------------------------------ FORMAT:100 pixels

"""
    Bruker100Blob(bytesperpixel, underflow, overflow1, overflow2, baseline, has_underflow)

Bruker `FORMAT:100` pixel encoding: a narrow base image plus up to three correction tables,
each padded to a multiple of 16 bytes and stored immediately after the pixels.

    <pixels>     NROWS x NCOLS of NPIXELB[1] bytes
    <underflow>  NOVERFL[1] signed values of NPIXELB[2] bytes   (absent when NOVERFL[1] < 1)
    <overflow1>  NOVERFL[2] UInt16 values
    <overflow2>  NOVERFL[3] Int32 values

Reconstruction escalates in two stages, and the order matters: every pixel reading 255 takes
the next value from `overflow1`, and only then does every pixel reading 65535 — including one
that just came from `overflow1` — take the next value from `overflow2`. Pixels reading zero
afterwards take the next `underflow` value, and every other pixel has the baseline added.
The tables are consumed in raster order, which is this array's memory order.

The baseline is the third `NEXP` field, or zero when `NOVERFL` begins with -1, which means the
file carries neither underflow table nor baseline.
"""
struct Bruker100Blob <: AbstractDataCodec
    bytesperpixel::Int
    underflow::Vector{Int32}
    overflow1::Vector{UInt16}
    overflow2::Vector{Int32}
    baseline::Int32
    has_underflow::Bool
end

"""Round `v` up to a multiple of 16, the padding every FORMAT:100 table uses."""
_bruker_pad16(v::Integer) = 16 * cld(Int(v), 16)

function _bruker100_codec(
    h::Header,
    src::AbstractSource,
    offset::Int,
    npixelb::Int,
    filesz::Int,
)
    nov = _bruker_ints(h, "NOVERFL", 3)
    ubpp = _bruker_int_at(h, "NPIXELB", 2, npixelb)

    pos = offset
    underflow = Int32[]
    has_underflow = nov[1] > 0
    if has_underflow
        underflow, pos = _bruker100_table(src, pos, nov[1], ubpp, true, filesz)
    end
    overflow1 = UInt16[]
    if nov[2] > 0
        raw, pos = _bruker100_table(src, pos, nov[2], 2, false, filesz)
        overflow1 = UInt16.(raw)
    end
    overflow2 = Int32[]
    if nov[3] > 0
        overflow2, pos = _bruker100_table(src, pos, nov[3], 4, true, filesz)
    end

    # -1 means the file carries neither underflow table nor baseline.
    baseline = nov[1] == -1 ? Int32(0) : Int32(_bruker_int_at(h, "NEXP", 3, 0))
    return Bruker100Blob(npixelb, underflow, overflow1, overflow2, baseline, has_underflow)
end

"""Read one padded correction table, returning its values and the position after the padding."""
function _bruker100_table(
    src::AbstractSource,
    pos::Int,
    count::Int,
    bpp::Int,
    signed::Bool,
    filesz::Int,
)
    need = count * bpp
    padded = _bruker_pad16(need)
    pos + padded > filesz && throw(
        TruncatedFileError(
            "Bruker100: a $count-entry table of $bpp-byte values needs $padded bytes at $pos, " *
            "but the file holds $filesz",
        ),
    )
    raw = bytes(src, pos, need)
    out = Vector{Int32}(undef, count)
    @inbounds for i = 1:count
        p = (i - 1) * bpp + 1
        out[i] = if bpp == 1
            signed ? Int32(reinterpret(Int8, raw[p])) : Int32(raw[p])
        elseif bpp == 2
            signed ? Int32(_load_i16(raw, p)) : Int32(_load_u16(raw, p))
        else
            _load_i32(raw, p)
        end
    end
    return out, pos + padded
end

function decode(c::Bruker100Blob, raw::AbstractVector{UInt8}, ::Type{Int32}, dims::Dims{2})
    S = get(BRUKER_BPP_TYPES, c.bytesperpixel, nothing)
    S === nothing &&
        throw(UnsupportedFormatError("Bruker100: NPIXELB=$(c.bytesperpixel) is not 1, 2 or 4"))
    return _bruker100_decode(c, raw, dims, S)
end

function _bruker100_decode(
    c::Bruker100Blob,
    raw::AbstractVector{UInt8},
    dims::Dims{2},
    ::Type{S},
) where {S}
    stored = decode(RawBlob(), raw, S, dims)
    isnative(LittleEndian()) || _fixbyteorder!(stored, LittleEndian())
    out = Array{Int32}(undef, dims)
    @inbounds for i in eachindex(out)
        out[i] = Int32(stored[i])
    end

    if sizeof(S) == 1 && !isempty(c.overflow1)
        _bruker100_patch!(out, Int32(255), c.overflow1, "overflow1")
    end
    if sizeof(S) < 4 && !isempty(c.overflow2)
        _bruker100_patch!(out, Int32(65535), c.overflow2, "overflow2")
    end

    if !c.has_underflow
        @inbounds for i in eachindex(out)
            out[i] += c.baseline
        end
    else
        k = 0
        n = length(c.underflow)
        @inbounds for i in eachindex(out)
            if out[i] == 0
                k += 1
                k <= n || throw(
                    CorruptFileError("Bruker100: more zero pixels than the $n underflow entries"),
                )
                out[i] = c.underflow[k]
            else
                out[i] += c.baseline
            end
        end
    end
    return out
end

"""Replace each pixel equal to `marker` with the next table entry, in raster order."""
function _bruker100_patch!(out::Array{Int32}, marker::Int32, table, what::AbstractString)
    k = 0
    n = length(table)
    @inbounds for i in eachindex(out)
        if out[i] == marker
            k += 1
            k <= n || throw(
                CorruptFileError("Bruker100: more pixels at $marker than the $n $what entries"),
            )
            out[i] = Int32(table[k])
        end
    end
    return out
end

_fixbyteorder!(A, ::ByteOrder, ::Bruker100Blob) = A

"""All whitespace-separated integers of a header value, padded with zeros to `n` entries."""
function _bruker_ints(h::Header, key::AbstractString, n::Int)
    out = zeros(Int, n)
    v = getci(h, key)
    v === nothing && return out
    for (i, tok) in enumerate(split(strip(String(v))))
        i > n && break
        p = tryparse(Int, tok)
        p === nothing || (out[i] = p)
    end
    return out
end

"""The `i`-th whitespace-separated integer of a header value, or `default`."""
function _bruker_int_at(h::Header, key::AbstractString, i::Int, default::Int)
    v = getci(h, key)
    v === nothing && return default
    toks = split(strip(String(v)))
    length(toks) < i && return default
    p = tryparse(Int, toks[i])
    return p === nothing ? default : p
end

"""Generic write entry point. Only `FORMAT:86` can be written. See [`writeformat`](@ref)."""
writeformat(fmt::Bruker{86}, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone(writebruker, fmt, path, arrays, headers; kwargs...)

"""The keys `writebruker` generates from the array itself. See [`layoutkeys`](@ref)."""
layoutkeys(::Bruker) = (
    "FORMAT", "VERSION", "HDRBLKS", "NROWS", "NCOLS", "NPIXELB", "NOVERFL", "datastart",
)

"""Bruker stores unsigned pixels of 1, 2 or 4 bytes. See [`storagetypes`](@ref)."""
storagetypes(::Bruker) = (UInt8, UInt16, UInt32)

"""Bruker stores unsigned pixels; see [`narrowstorage`](@ref) for how the width is chosen."""
coerce(fmt::Bruker, A::AbstractArray{<:Any,2}) = narrowstorage(fmt, A)

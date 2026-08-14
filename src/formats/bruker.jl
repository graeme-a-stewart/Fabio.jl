"""
    Bruker <: ImageFormat

Bruker `FORMAT:86` frames, as written by Bruker area detectors (`.sfrm` and friends).

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

`FORMAT:100` files are a different layout — three separate overflow, underflow and baseline
blocks — and are refused rather than misread by this reader.
"""
struct Bruker <: ImageFormat end

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

function scan(::Bruker, src::AbstractSource)
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
    version == 86 || throw(
        UnsupportedFormatError(
            "Bruker FORMAT:$version is not supported; only FORMAT:86 is. A 100-format file " *
            "stores its overflows, underflows and baseline in three separate padded blocks, " *
            "so reading it as 86 would silently give wrong pixel values.",
        ),
    )

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
    for (k, v) in header
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

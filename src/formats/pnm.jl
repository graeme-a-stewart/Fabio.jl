"""
    PNM <: ImageFormat

Netpbm images: PGM greyscale (`P2` ASCII, `P5` binary) and PBM bitmaps (`P1` ASCII, `P4`
packed). These are the greyscale members of the family, which is what detector software and
mask tools use.

The colour formats `P3`/`P6` and the `P7`/PAM container are refused with a clear message
rather than read: they carry several samples per pixel, which this package's single-channel
image model has nowhere to put.

# On-disk structure

    P5
    # an optional comment, to end of line
    1024 1024
    65535
    <one whitespace byte><binary pixels>

Header fields are whitespace-separated and `#` runs to end of line, so the width and height may
sit on one line or several. `MAXVAL` selects the pixel type — up to 255 is `UInt8`, up to 65535
is `UInt16` — and **binary values wider than a byte are big-endian**, as the netpbm
specification requires.
"""
struct PNM <: ImageFormat end

"""ASCII-encoded pixels: whitespace-separated decimal integers (`P1`, `P2`)."""
struct PnmASCII <: AbstractDataCodec
    bits::Bool          # true for P1, where each token is a single 0/1 and 1 means black
end

"""Packed one-bit-per-pixel rows, each row padded to a byte boundary (`P4`)."""
struct PnmBitmap <: AbstractDataCodec end

function decode(c::PnmASCII, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    out = Array{T}(undef, dims)
    n = length(out)
    k = 0
    i = 1
    len = length(raw)
    @inbounds while i <= len && k < n
        b = raw[i]
        if b == UInt8('#')                       # comments may appear among the values
            while i <= len && raw[i] != UInt8('\n')
                i += 1
            end
            i += 1
            continue
        elseif b <= UInt8(' ')
            i += 1
            continue
        end
        if c.bits
            # A plain PBM pixel is a single character. Whitespace between them is allowed
            # but not required, and netpbm writes none — so reading whitespace-delimited
            # tokens swallows an entire row as one enormous number.
            d = b - UInt8('0')
            d > 1 && throw(CorruptFileError("PNM: $(repr(Char(b))) is not a bit"))
            k += 1
            out[k] = T(d == 0 ? 1 : 0)           # a set bit is black
            i += 1
        else
            v = 0
            while i <= len && raw[i] > UInt8(' ') && raw[i] != UInt8('#')
                d = raw[i] - UInt8('0')
                d > 9 && throw(CorruptFileError("PNM: non-numeric byte in ASCII pixel data"))
                v = v * 10 + Int(d)
                i += 1
            end
            k += 1
            out[k] = T(v)
        end
    end
    k == n || throw(TruncatedFileError("PNM: found $k of $n ASCII pixel values"))
    return out
end

function decode(::PnmBitmap, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    nfast, nslow = dims
    rowbytes = cld(nfast, 8)
    length(raw) < rowbytes * nslow &&
        throw(TruncatedFileError("PNM: packed bitmap is shorter than $(rowbytes * nslow) bytes"))
    out = Array{T}(undef, dims)
    @inbounds for y = 1:nslow, x = 1:nfast
        byte = raw[(y-1)*rowbytes+((x-1)>>3)+1]
        bit = (byte >> (7 - ((x - 1) & 7))) & 0x01
        out[x, y] = T(bit == 1 ? 0 : 1)      # a set bit is black
    end
    return out
end

"""
Read the next whitespace-delimited token. Returns `(token, newpos)`.

Any `#` comments passed over are appended to `comments` rather than dropped: they are the only
metadata a Netpbm file can carry, so discarding them would leave the header with nothing but
the image geometry.
"""
function _pnm_token(src::AbstractSource, pos::Int, comments::Vector{String} = String[])
    n = filesize(src)
    i = pos
    while i < n
        b = _byteat(src, i)
        if b == UInt8('#')
            start = i + 1
            while i < n && _byteat(src, i) != UInt8('\n')
                i += 1
            end
            text = strip(String(Char.(bytes(src, start, i - start))))
            isempty(text) || push!(comments, String(text))
        elseif b <= UInt8(' ')
            i += 1
        else
            break
        end
    end
    i >= n && throw(TruncatedFileError("PNM: header ended early"))
    start = i
    while i < n && _byteat(src, i) > UInt8(' ') && _byteat(src, i) != UInt8('#')
        i += 1
    end
    return String(Char.(bytes(src, start, i - start))), i
end

function scan(::PNM, src::AbstractSource)
    comments = String[]
    magic, pos = _pnm_token(src, 0, comments)
    magic in ("P1", "P2", "P4", "P5") || throw(
        UnsupportedFormatError(
            magic in ("P3", "P6", "P7") ?
            "PNM subformat $magic carries several samples per pixel and is not supported" :
            "PNM: unknown subformat $(repr(magic))",
        ),
    )

    wtok, pos = _pnm_token(src, pos, comments)
    htok, pos = _pnm_token(src, pos, comments)
    width = something(tryparse(Int, wtok), 0)
    height = something(tryparse(Int, htok), 0)
    (width > 0 && height > 0) ||
        throw(CorruptFileError("PNM: bad dimensions $(repr(wtok)) x $(repr(htok))"))

    bitmap = magic in ("P1", "P4")
    maxval = 1
    if !bitmap
        mtok, pos = _pnm_token(src, pos, comments)
        maxval = something(tryparse(Int, mtok), 0)
        maxval > 0 || throw(CorruptFileError("PNM: bad MAXVAL $(repr(mtok))"))
    end

    T = if maxval < 256
        UInt8
    elseif maxval < 65536
        UInt16
    else
        throw(UnsupportedFormatError("PNM: MAXVAL $maxval exceeds 16 bits"))
    end

    h = Header()
    h["SUBFORMAT"] = magic
    h["WIDTH"] = width
    h["HEIGHT"] = height
    h["MAXVAL"] = maxval
    # Several comment lines join with newlines, the same convention the Bruker reader uses
    # for a key repeated across lines.
    isempty(comments) || (h["Comments"] = join(comments, "\n"))

    # Exactly one whitespace byte separates the header from binary data.
    dataoffset = magic in ("P4", "P5") ? pos + 1 : pos
    n = filesize(src)
    dataoffset >= n && throw(TruncatedFileError("PNM: no pixel data after the header"))

    codec, nbytes = if magic == "P5"
        (RawBlob(), width * height * sizeof(T))
    elseif magic == "P4"
        (PnmBitmap(), cld(width, 8) * height)
    else
        (PnmASCII(magic == "P1"), n - dataoffset)
    end
    dataoffset + nbytes > n &&
        throw(TruncatedFileError("PNM: needs $nbytes bytes of pixels, file holds $(n - dataoffset)"))

    layout = BinaryLayout{T}(
        dataoffset,
        nbytes,
        (width, height);
        byteorder = BigEndian(),      # netpbm stores multi-byte samples most significant first
        codec = codec,
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

# The ASCII and bitmap codecs produce host-order values already.
_fixbyteorder!(A, ::ByteOrder, ::PnmASCII) = A
_fixbyteorder!(A, ::ByteOrder, ::PnmBitmap) = A

"""
    writepnm(path, A; ascii = false, comment = "")

Write a binary (`P5`) or ASCII (`P2`) greyscale PGM. `MAXVAL` follows the element type.

`comment` is written as `#` lines, one per embedded newline, which is the only metadata the
format admits. Passing back the `Comments` entry the reader produces round-trips it.
"""
function writepnm(
    path::AbstractString,
    A::AbstractArray{T,2};
    ascii::Bool = false,
    comment::AbstractString = "",
) where {T<:Union{UInt8,UInt16}}
    width, height = size(A)
    maxval = T === UInt8 ? 255 : 65535
    io = IOBuffer()
    print(io, ascii ? "P2\n" : "P5\n")
    for line in split(comment, '\n')
        isempty(strip(line)) || print(io, "# ", line, "\n")
    end
    print(io, width, " ", height, "\n", maxval, "\n")
    Base.open(path, "w") do f
        Base.write(f, take!(io))
        if ascii
            for y = 1:height
                Base.write(f, codeunits(join((string(A[x, y]) for x = 1:width), " ")), UInt8('\n'))
            end
        else
            Base.write(f, T === UInt8 ? vec(collect(A)) : reinterpret(UInt8, hton.(vec(collect(A)))))
        end
    end
    return path
end

"""Generic write entry point. See [`writeformat`](@ref)."""
writeformat(fmt::PNM, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone((p, a, _h; kw...) -> writepnm(p, a; kw...), fmt, path, arrays, headers; kwargs...)

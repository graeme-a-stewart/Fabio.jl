"""
    Fit2D <: ImageFormat

Andy Hammersley's Fit2D binary format (`.f2d`). Unlike the other formats here it has no fixed
header: the file is a sequence of self-describing records, each introduced by a block that
begins with a backslash.

# On-disk structure

Records are laid out in blocks of `BLOCK` bytes (512 by default). A record's opening block is

    \\KEY:NNNNNNNNt…

where `NNNNNNNN` is the count of payload blocks following, as eight hexadecimal digits, and `t`
is the record kind:

| kind | meaning | encoding |
|---|---|---|
| `s` | string | eight hex digits of length, then that many ASCII bytes |
| `i` | integer | eight hex digits |
| `r` | real | eight hex digits, the IEEE-754 bit pattern of a `Float32` |
| `a` | array | array type at offset 9, dimensions at offsets 26 and 34 |

An array record is followed by `NNNNNNNN` payload blocks. Array types are `i` for `Int32`, `r`
for `Float32`, and `l` for a bit mask packed 31 pixels to an `Int32` — see
`Fit2DBitmask`. The image itself is the record named `data_array`.

# Byte order

The format does not record its own byte order, and FabIO is inconsistent about it: it decodes
`i` and `r` arrays with numpy's **native** order, but `l` masks explicitly as big-endian, in the
same function.

Real files settle it: `.f2d` arrays are **little-endian**. Read as big-endian, FabIO's own test
files come back as denormals — `fit2d.f2d` gives a maximum of 1.8e-38 where it should give 1793
— so that is the default here. `Fit2D{:big}` remains available:

    Fabio.openimage(path; format = Fit2D{:big}())

Whether FabIO's big-endian `l` mask branch is right for masks specifically is untested, since
no file of that kind was to hand. The scalar `i` and `r` fields are hexadecimal text and are
unaffected either way.

# Two further divergences from FabIO

FabIO's `hex_to(stg, "float")` never looks at `stg`. It returns
`numpy.array([int("38d1b717", 16)], "int32").view("float32")[0]`, a hardcoded constant of about
1.0e-4, so **every real-valued field in every `.f2d` file reads back as the same number**. It
is plainly a test value that was never removed. This reader decodes the digits it is given.

FabIO also handles a file whose block size is not 512 by rescanning with a larger size, but
after computing the new size it seeks back to the start and then parses the *stale* block it
had already read, rather than resuming the scan. This reader restarts the scan properly.
"""
struct Fit2D{Order} <: ImageFormat end

Fit2D() = Fit2D{:little}()

const FIT2D_BLOCK = 512
const FIT2D_PIXELS_PER_CHUNK = 128

"""
    Fit2DChunked(stride, keep)

Array payloads store `keep` pixels in every `stride` bytes, the remainder being padding. With
the default 512-byte block and four-byte pixels the two coincide and no padding exists, which
is why the effect only shows up in files written with a larger block size.
"""
struct Fit2DChunked <: AbstractDataCodec
    stride::Int          # bytes per block
    keep::Int            # pixels taken from each block
    bigendian::Bool
end

"""
    Fit2DBitmask()

Fit2D's mask packing: **31** pixels to a big-endian `Int32`, the sign bit unused, and the
pixels within each word stored in reverse order.
"""
struct Fit2DBitmask <: AbstractDataCodec end

function decode(c::Fit2DChunked, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    n = prod(dims)
    out = Array{T}(undef, dims)
    bpp = sizeof(T)
    k = 0
    pos = 0
    @inbounds while k < n && pos < length(raw)
        take = min(c.keep, n - k)
        for j = 0:(take-1)
            off = pos + j * bpp
            off + bpp > length(raw) && break
            out[k+j+1] = _fit2d_value(T, raw, off + 1, c.bigendian)
        end
        k += take
        pos += c.stride
    end
    k >= n || throw(TruncatedFileError("Fit2D: array holds $k of $n pixels"))
    return out
end

@inline _fit2d_value(::Type{Int32}, raw, i, be) = be ? bswap(_load_i32(raw, i)) : _load_i32(raw, i)
@inline _fit2d_value(::Type{Float32}, raw, i, be) =
    reinterpret(Float32, _fit2d_value(Int32, raw, i, be))

function decode(::Fit2DBitmask, raw::AbstractVector{UInt8}, ::Type{UInt8}, dims::Dims{2})
    n = prod(dims)
    out = Array{UInt8}(undef, dims)
    words = length(raw) ÷ 4
    k = 0
    @inbounds for w = 1:words
        k >= n && break
        v = bswap(_load_u32(raw, 4(w - 1) + 1))
        # 31 pixels per word, the sign bit unused, stored in reverse order.
        for b = 1:31
            k >= n && break
            k += 1
            out[k] = UInt8((v >> (31 - b)) & 0x01)
        end
    end
    k >= n || throw(TruncatedFileError("Fit2D: bit mask holds $k of $n pixels"))
    return out
end

_fixbyteorder!(A, ::ByteOrder, ::Fit2DChunked) = A
_fixbyteorder!(A, ::ByteOrder, ::Fit2DBitmask) = A

"""Parse eight hexadecimal digits."""
function _fit2d_hex(s::AbstractString)
    v = tryparse(UInt32, strip(s), base = 16)
    v === nothing && throw(CorruptFileError("Fit2D: $(repr(s)) is not a hex field"))
    return v
end

function scan(::Fit2D{Order}, src::AbstractSource) where {Order}
    block = _fit2d_blocksize(src)
    n = filesize(src)
    h = Header()
    h["BlockSize"] = block
    h["ByteOrder"] = Order === :big ? "HighByteFirst" : "LowByteFirst"
    imagespec = nothing

    pos = 0
    while pos + block <= n
        head = String(Char.(bytes(src, pos, block)))
        first(head) == '\\' || break
        colon = findfirst(':', head)
        colon === nothing && break
        key = String(head[2:prevind(head, colon)])
        body = head[nextind(head, colon):end]
        length(body) < 9 && break
        nblocks = Int(_fit2d_hex(body[1:8]))
        kind = body[9]
        pos += block

        if kind == 's'
            len = Int(_fit2d_hex(body[10:17]))
            h[key] = String(strip(body[18:min(17 + len, length(body))]))
        elseif kind == 'i'
            h[key] = Int(reinterpret(Int32, _fit2d_hex(body[10:17])))
        elseif kind == 'r'
            # FabIO returns a hardcoded constant here regardless of the digits present.
            h[key] = Float64(reinterpret(Float32, _fit2d_hex(body[10:17])))
        elseif kind == 'a' && nblocks > 0
            arraytype = body[10]
            d1 = Int(_fit2d_hex(body[27:34]))
            d2 = Int(_fit2d_hex(body[35:42]))
            (d1 > 0 && d2 > 0) ||
                throw(CorruptFileError("Fit2D: array $key has dimensions ($d1, $d2)"))
            nbytes = nblocks * block
            pos + nbytes > n &&
                throw(TruncatedFileError("Fit2D: array $key wants $nbytes bytes past $pos"))

            bo = Order === :big ? BigEndian() : LittleEndian()
            T, codec = if arraytype == 'i'
                (Int32, Fit2DChunked(block, min(FIT2D_PIXELS_PER_CHUNK, block ÷ 4), Order === :big))
            elseif arraytype == 'r'
                (Float32, Fit2DChunked(block, min(FIT2D_PIXELS_PER_CHUNK, block ÷ 4), Order === :big))
            elseif arraytype == 'l'
                (UInt8, Fit2DBitmask())
            else
                throw(UnsupportedFormatError("Fit2D: array type $(repr(arraytype)) in $key"))
            end

            layout = BinaryLayout{T}(
                pos, nbytes, (d1, d2); byteorder = bo, codec = codec)
            if key == "data_array" || imagespec === nothing
                imagespec = (key, layout)
            end
            h["$(key)_dims"] = (d1, d2)
            pos += nbytes
        elseif nblocks > 0
            pos += nblocks * block          # a record kind we do not interpret
        end
    end

    imagespec === nothing &&
        throw(CorruptFileError("Fit2D: no array record found (expected one named data_array)"))
    h["ImageRecord"] = imagespec[1]
    return Header(), FrameSpec[FrameSpec(h, imagespec[2])]
end

"""
Determine the block size.

Records begin on a block boundary with a backslash, so the size is the smallest multiple of 512
for which the second record starts with one. FabIO searches the same way but then parses a
stale block instead of restarting; this restarts.
"""
function _fit2d_blocksize(src::AbstractSource)
    n = filesize(src)
    n >= FIT2D_BLOCK || throw(TruncatedFileError("Fit2D: file is shorter than one block"))
    _byteat(src, 0) == UInt8('\\') ||
        throw(CorruptFileError("Fit2D: file does not begin with a record marker"))
    for mult = 1:15
        block = FIT2D_BLOCK * mult
        block <= n || break
        # The first record is a string or scalar with no payload, so the next record — if the
        # file holds one — begins exactly one block later.
        block == n && return block
        _byteat(src, block) == UInt8('\\') && return block
    end
    return FIT2D_BLOCK
end

"""
    writefit2d(path, A; strings = Dict(), integers = Dict(), reals = Dict())

Write a `.f2d` file holding `A` as the `data_array` record, preceded by the `\$FFF_START`
marker and any scalar records given. `Int32` and `Float32` arrays are supported.
"""
function writefit2d(
    path::AbstractString,
    A::AbstractArray{T,2};
    bigendian::Bool = false,
    strings = Dict{String,String}(),
    integers = Dict{String,Int}(),
    reals = Dict{String,Float64}(),
) where {T<:Union{Int32,Float32}}
    d1, d2 = size(A)
    io = IOBuffer()
    pad(s) = (b = Vector{UInt8}(codeunits(s));
              vcat(b, fill(UInt8(' '), FIT2D_BLOCK - length(b))))

    write(io, pad("\\\$FFF_START:00000000i" * string(0, base = 16, pad = 8)))
    for (k, v) in strings
        write(io, pad("\\$k:00000000s" * string(length(v), base = 16, pad = 8) * v))
    end
    for (k, v) in integers
        write(io, pad("\\$k:00000000i" * string(reinterpret(UInt32, Int32(v)), base = 16, pad = 8)))
    end
    for (k, v) in reals
        bits = reinterpret(UInt32, Float32(v))
        write(io, pad("\\$k:00000000r" * string(bits, base = 16, pad = 8)))
    end

    payload = UInt8[]
    perblock = FIT2D_BLOCK ÷ 4
    flat = vec(collect(A))
    for start = 1:perblock:length(flat)
        chunk = flat[start:min(start + perblock - 1, end)]
        for v in chunk
            append!(payload, reinterpret(UInt8, [bigendian ? hton(v) : htol(v)]))
        end
        append!(payload, zeros(UInt8, FIT2D_BLOCK - 4 * length(chunk)))
    end
    nblocks = length(payload) ÷ FIT2D_BLOCK

    atype = T === Int32 ? 'i' : 'r'
    head = "\\data_array:" * string(nblocks, base = 16, pad = 8) * "a" * atype
    head *= "0"^16                                     # bytes 10..25, unused
    head *= string(d1, base = 16, pad = 8) * string(d2, base = 16, pad = 8)
    write(io, pad(head))
    write(io, payload)

    Base.open(path, "w") do f
        Base.write(f, take!(io))
    end
    return path
end

"""
Fit2D stores its `data_array` record as `Int32` or `Float32`, and nothing else.

A float input keeps its fractional part by narrowing to `Float32`; an integer input becomes
`Int32`. This is the gap the generic write path exposed: `writefit2d` rightly refuses anything
else, so without a `coerce` method `writeimage("x.f2d", ::Matrix{UInt16})` was a `MethodError`
from two calls down rather than a conversion the format asks for.
"""
function coerce(::Fit2D, A::AbstractArray{T,2}) where {T}
    (T === Int32 || T === Float32) && return A
    if T <: AbstractFloat
        return convert(Array{Float32}, A)
    end
    any(x -> x < typemin(Int32) || x > typemax(Int32), A) &&
        @warn "Fit2D stores 32-bit signed integers; values outside that range will wrap"
    return convert(Array{Int32}, A .% Int32)
end

"""Generic write entry point. See [`writeformat`](@ref)."""
writeformat(fmt::Fit2D, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone((p, a, _h; kw...) -> writefit2d(p, a; kw...), fmt, path, arrays, headers; kwargs...)

"""Fit2D's record bookkeeping. See [`layoutkeys`](@ref)."""
layoutkeys(::Fit2D) = ("BlockSize", "ByteOrder", "\$FFF_START", "data_array_dims", "ImageRecord")

"""Fit2D's data_array record is `Int32` or `Float32`. See [`storagetypes`](@ref)."""
storagetypes(::Fit2D) = (Int32, Float32)

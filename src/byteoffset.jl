"""
    ByteOffset()

The `x-CBF_BYTE_OFFSET` codec of the CIF binary format, used by Pilatus, Eiger-to-CBF
converters and most of the crystallography world.

# Format

Pixels are stored as differences from the previous pixel in raster order, one signed byte each.
A delta that does not fit escalates: the byte `0x80` introduces a 16-bit little-endian value,
`0x80` followed by `Int16` `typemin` introduces a 32-bit one, and that followed by `Int32`
`typemin` introduces a 64-bit one. The image is recovered by a cumulative sum over the whole
frame — across rows, not per row, unlike [`AGIBitfield`](@ref).

Accumulation happens in the signed type of the same width as `T` and is reinterpreted at the
end, so unsigned images wrap exactly as FabIO's numpy implementation does.
"""
struct ByteOffset <: AbstractDataCodec end

_accumtype(::Type{T}) where {T<:Signed} = T
_accumtype(::Type{T}) where {T<:Unsigned} = signed(T)

function decode(::ByteOffset, raw::AbstractVector{UInt8}, ::Type{T}, dims::Dims{2}) where {T}
    S = _accumtype(T)
    n = prod(dims)
    out = Array{T}(undef, dims)
    len = length(raw)
    i = 1
    acc = zero(S)

    @inbounds for k = 1:n
        i > len && throw(
            TruncatedFileError("byte-offset stream ended after $(k - 1) of $n pixels"),
        )
        b = raw[i]
        i += 1
        if b != 0x80
            acc += reinterpret(Int8, b) % S
        else
            i + 1 > len && throw(TruncatedFileError("byte-offset: truncated 16-bit escape"))
            d16 = _load_i16(raw, i)
            i += 2
            if d16 != typemin(Int16)
                acc += d16 % S
            else
                i + 3 > len &&
                    throw(TruncatedFileError("byte-offset: truncated 32-bit escape"))
                d32 = _load_i32(raw, i)
                i += 4
                if d32 != typemin(Int32)
                    acc += d32 % S
                else
                    i + 7 > len &&
                        throw(TruncatedFileError("byte-offset: truncated 64-bit escape"))
                    acc += _load_i64(raw, i) % S
                    i += 8
                end
            end
        end
        # `%` reinterprets rather than converting, so unsigned images wrap exactly as
        # numpy's cast does in FabIO instead of throwing on a negative running total.
        out[k] = acc % T
    end
    return out
end

function encode(::ByteOffset, A::AbstractArray{T,2}) where {T}
    S = _accumtype(T)
    out = UInt8[]
    sizehint!(out, length(A))
    prev = zero(S)
    @inbounds for k in eachindex(A)
        cur = A[k] % S
        d = widen(cur) - widen(prev)
        prev = cur
        if -127 <= d <= 127
            push!(out, reinterpret(UInt8, Int8(d)))
        else
            push!(out, 0x80)
            if -32767 <= d <= 32767
                _push_le!(out, Int16(d))
            else
                _push_le!(out, typemin(Int16))
                if -2147483647 <= d <= 2147483647
                    _push_le!(out, Int32(d))
                else
                    _push_le!(out, typemin(Int32))
                    _push_le!(out, Int64(d))
                end
            end
        end
    end
    return out
end

@inline function _push_le!(out::Vector{UInt8}, v::Integer)
    u = reinterpret(unsigned(typeof(v)), v)
    for i = 0:(sizeof(v)-1)
        push!(out, UInt8((u >> (8 * i)) & 0xFF))
    end
    return out
end

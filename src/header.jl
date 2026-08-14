"""
    Header <: AbstractDict{String,Any}

Ordered, case-insensitively searchable metadata dictionary.

Values are stored **as recorded in the file**; conversion happens at the point of use via
[`getheader`](@ref). This follows FabIO's documented contract: information about the binary
part of the image (compression, endianness, shape) is interpreted by the reader into a
[`BinaryLayout`](@ref), while all other metadata is exposed exactly as it appears on disk.

Insertion order is preserved so a writer can round-trip a header faithfully.
"""
struct Header <: AbstractDict{String,Any}
    dict::OrderedDict{String,Any}
    ci::Dict{String,String}   # UPPERCASE key -> canonical key
end

Header() = Header(OrderedDict{String,Any}(), Dict{String,String}())

function Header(pairs)
    h = Header()
    for (k, v) in pairs
        h[String(k)] = v
    end
    return h
end

Base.length(h::Header) = length(h.dict)
Base.iterate(h::Header) = iterate(h.dict)
Base.iterate(h::Header, s) = iterate(h.dict, s)
Base.keys(h::Header) = keys(h.dict)
Base.values(h::Header) = values(h.dict)
Base.haskey(h::Header, k::AbstractString) = haskey(h.dict, String(k))
Base.getindex(h::Header, k::AbstractString) = h.dict[String(k)]
Base.get(h::Header, k::AbstractString, default) = get(h.dict, String(k), default)

function Base.setindex!(h::Header, v, k::AbstractString)
    key = String(k)
    h.dict[key] = v
    h.ci[uppercase(key)] = key
    return v
end

function Base.delete!(h::Header, k::AbstractString)
    key = String(k)
    delete!(h.dict, key)
    delete!(h.ci, uppercase(key))
    return h
end

Base.copy(h::Header) = Header(copy(h.dict), copy(h.ci))

function Base.merge!(dst::Header, src::Header)
    for (k, v) in src
        dst[k] = v
    end
    return dst
end

"""
    canonicalkey(h::Header, key) -> Union{String,Nothing}

Resolve `key` case-insensitively to the key as actually spelled in the file.
Formats such as EDF are inconsistent about capitalisation between writers.
"""
canonicalkey(h::Header, key::AbstractString) = get(h.ci, uppercase(String(key)), nothing)

"""
    getci(h::Header, key, default=nothing)

Case-insensitive `get`.
"""
function getci(h::Header, key::AbstractString, default = nothing)
    k = canonicalkey(h, key)
    k === nothing ? default : h.dict[k]
end

"""
    getheader(h::Header, key, ::Type{T}) -> T
    getheader(h::Header, key, ::Type{T}, default) -> T

Look `key` up case-insensitively and convert the value to `T`. The three-argument form
throws a [`CorruptFileError`](@ref) if the key is missing or cannot be converted; the
four-argument form returns `default` instead.

```julia
getheader(header(frame), "ESRFCurrent", Float64)
getheader(header(frame), "Dim_1", Int)
```
"""
function getheader(h::Header, key::AbstractString, ::Type{T}) where {T}
    v = getci(h, key)
    v === nothing && throw(CorruptFileError("missing header key \"$key\""))
    parsed = _convert_header(T, v)
    parsed === nothing &&
        throw(CorruptFileError("header key \"$key\" = $(repr(v)) is not a $T"))
    return parsed::T
end

function getheader(h::Header, key::AbstractString, ::Type{T}, default) where {T}
    v = getci(h, key)
    v === nothing && return default
    parsed = _convert_header(T, v)
    return parsed === nothing ? default : parsed::T
end

_convert_header(::Type{T}, v) where {T} = v isa T ? v : nothing
_convert_header(::Type{String}, v::AbstractString) = String(v)
_convert_header(::Type{String}, v::Any) = string(v)
_convert_header(::Type{T}, v::AbstractString) where {T<:Number} = tryparse(T, strip(v))
function _convert_header(::Type{T}, v::Number) where {T<:Number}
    try
        return convert(T, v)
    catch
        return nothing
    end
end

function Base.show(io::IO, ::MIME"text/plain", h::Header)
    println(io, "Header with ", length(h), " entr", length(h) == 1 ? "y" : "ies", ":")
    for (i, (k, v)) in enumerate(h)
        if i > 40
            println(io, "  ⋮ (", length(h) - 40, " more)")
            break
        end
        s = repr(v)
        length(s) > 68 && (s = s[1:65] * "…")
        println(io, "  ", k, " => ", s)
    end
end

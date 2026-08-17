"""
    MPA <: ImageFormat

Multi-wire detector data (`.mpa`), as written by FastComTec multi-parameter systems.

# On-disk structure

An INI-style text header, then the values:

    [ADC1]
    range=512
    …
    [ADC2]
    range=512
    …
    mpafmt=asc
    [CDAT0,262144]
    17
    0
    23
    …

Section names prefix the keys beneath them, so `range` under `[ADC1]` becomes `ADC1_range`;
keys before any section keep their bare names. `ADC1_range` is the slow axis and `ADC2_range`
the fast one. The values follow the `[CDAT…]` (or `[DATA…]`) marker, one decimal number per
line, and are read as `Float64` to match FabIO.

Despite the `mpafmt` key, FabIO parses the values as text either way — its "binary" branch
reopens the file in binary mode and still splits it into lines and parses them as floats — so
there is only the one encoding to support.
"""
struct MPA <: ImageFormat end

"""One decimal number per line, as the `.mpa` data section stores them."""
struct MpaASCII <: AbstractDataCodec end

function decode(::MpaASCII, raw::AbstractVector{UInt8}, ::Type{Float64}, dims::Dims{2})
    out = Array{Float64}(undef, dims)
    n = length(out)
    k = 0
    i = 1
    len = length(raw)
    @inbounds while i <= len && k < n
        while i <= len && raw[i] <= UInt8(' ')
            i += 1
        end
        i > len && break
        start = i
        while i <= len && raw[i] > UInt8(' ')
            i += 1
        end
        tok = String(Char.(@view raw[start:(i-1)]))
        v = tryparse(Float64, tok)
        v === nothing && throw(CorruptFileError("MPA: $(repr(tok)) is not a number"))
        k += 1
        out[k] = v
    end
    k == n || throw(TruncatedFileError("MPA: found $k of $n values"))
    return out
end

_fixbyteorder!(A, ::ByteOrder, ::MpaASCII) = A

function scan(::MPA, src::AbstractSource)
    n = filesize(src)
    text = String(Char.(bytes(src, 0, n)))

    h = Header()
    section = ""
    dataoffset = -1
    pos = 1
    while pos <= ncodeunits(text)
        nl = findnext('\n', text, pos)
        stop = nl === nothing ? ncodeunits(text) : nl - 1
        line = strip(text[pos:stop])
        nextpos = nl === nothing ? ncodeunits(text) + 1 : nl + 1
        if startswith(line, "[DATA") || startswith(line, "[CDAT")
            h["DataMarker"] = String(line)
            dataoffset = nextpos - 1        # 0-based offset of the first value
            break
        elseif occursin('=', line)
            i = findfirst('=', line)
            key = String(strip(line[1:prevind(line, i)]))
            val = String(strip(line[nextind(line, i):end]))
            isempty(key) || (h[isempty(section) ? key : section * "_" * key] = val)
        elseif startswith(line, "[")
            section = String(strip(line, ['[', ']']))
        end
        pos = nextpos
    end

    dataoffset < 0 &&
        throw(CorruptFileError("MPA: no [DATA…] or [CDAT…] marker, so no pixel data"))

    slow = getheader(h, "ADC1_range", Int, 0)
    fast = getheader(h, "ADC2_range", Int, 0)
    (fast > 0 && slow > 0) || throw(
        CorruptFileError("MPA: ADC1_range and ADC2_range are needed for the shape ($slow, $fast)"),
    )

    layout = BinaryLayout{Float64}(
        dataoffset,
        n - dataoffset,
        (fast, slow);
        byteorder = LittleEndian(),
        codec = MpaASCII(),
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""
    writempa(path, A; sections = Dict())

Write an `.mpa` file: an INI-style header giving the shape, then one value per line.
"""
function writempa(
    path::AbstractString,
    A::AbstractArray{<:Real,2};
    sections = Dict{String,Dict{String,Any}}(),
)
    fast, slow = size(A)
    io = IOBuffer()
    # Every key after a section header belongs to that section, so anything meant to stay
    # unprefixed has to precede the first one.
    print(io, "mpafmt=asc\n")
    print(io, "[ADC1]\nrange=", slow, "\n")
    print(io, "[ADC2]\nrange=", fast, "\n")
    for (name, kv) in sections
        print(io, "[", name, "]\n")
        for (k, v) in kv
            print(io, k, "=", v, "\n")
        end
    end
    print(io, "[CDAT0,", length(A), "]\n")
    for v in vec(collect(A))
        print(io, v isa Integer ? string(v) : string(Float64(v)), "\n")
    end
    Base.open(path, "w") do f
        Base.write(f, take!(io))
    end
    return path
end

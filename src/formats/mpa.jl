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
the fast one, one decimal number per line, read as `Float64` to match FabIO.

A file typically holds several blocks: a `[DATA…]` block per ADC, each a one-dimensional
spectrum, followed by a `[CDAT…]` block holding the two-dimensional coincidence map. **The
image is the `[CDAT…]` block**, so the earlier ones are skipped — taking the first marker
found gives a 1024-value spectrum where a 1024×1024 image was wanted.

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
    fallback = -1
    inheader = true
    pos = 1
    while pos <= ncodeunits(text)
        nl = findnext('\n', text, pos)
        stop = nl === nothing ? ncodeunits(text) : nl - 1
        line = strip(text[pos:stop])
        nextpos = nl === nothing ? ncodeunits(text) + 1 : nl + 1
        if startswith(line, "[CDAT")
            # The coincidence block is the image. Any [DATA…] blocks before it are
            # one-dimensional per-ADC spectra, so they are skipped rather than read.
            h["DataMarker"] = String(line)
            dataoffset = nextpos - 1        # 0-based offset of the first value
            break
        elseif startswith(line, "[DATA")
            # Header parsing ends here, but the image may still be further down.
            haskey(h, "FirstDataMarker") || (h["FirstDataMarker"] = String(line))
            fallback < 0 && (fallback = nextpos - 1)
            inheader = false
        elseif inheader && occursin('=', line)
            i = findfirst('=', line)
            key = String(strip(line[1:prevind(line, i)]))
            val = String(strip(line[nextind(line, i):end]))
            isempty(key) || (h[isempty(section) ? key : section * "_" * key] = val)
        elseif inheader && startswith(line, "[")
            section = String(strip(line, ['[', ']']))
        end
        pos = nextpos
    end

    if dataoffset < 0
        # A file with only [DATA…] blocks and no [CDAT…]: take the first one.
        fallback < 0 &&
            throw(CorruptFileError("MPA: no [DATA…] or [CDAT…] marker, so no pixel data"))
        dataoffset = fallback
        h["DataMarker"] = h["FirstDataMarker"]
    end

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

"""Generic write entry point. See [`writeformat`](@ref)."""
writeformat(fmt::MPA, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone((p, a, _h; kw...) -> writempa(p, a; kw...), fmt, path, arrays, headers; kwargs...)

"""The MPA fields that give the array its shape and encoding. See [`layoutkeys`](@ref)."""
layoutkeys(::MPA) = ("mpafmt", "ADC1_range", "ADC2_range", "DataMarker")

"""The MPA reader returns counts as `Float64`. See [`storagetypes`](@ref)."""
storagetypes(::MPA) = (Float64,)

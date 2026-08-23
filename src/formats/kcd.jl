"""
    KCD <: ImageFormat

Nonius KappaCCD frames (`.kcd`).

# On-disk structure

    an ASCII header of `key = value` lines, ending at the first line that is not
    text or carries no '='
    …
    end of file    `Number of readouts` images of `X dimension` x `Y dimension`
                   `UInt16` little-endian values

Like R-AXIS, the pixels are found by counting **backwards from the end of the file** rather
than forwards from the header, since the header length is not fixed.

# Readouts

A KappaCCD frame may be read out several times and the readouts stored consecutively. They are
not separate frames: the image is their **sum**, which is why the result is `Int32` rather than
the `UInt16` the file stores. A single-readout file still comes back as `Int32`, matching FabIO,
so the element type does not depend on how the detector was operated.
"""
struct KCD <: ImageFormat end

"""Sum `n` consecutive `UInt16` readouts into one `Int32` image."""
struct KcdReadouts <: AbstractDataCodec
    readouts::Int
end

function decode(c::KcdReadouts, raw::AbstractVector{UInt8}, ::Type{Int32}, dims::Dims{2})
    n = prod(dims)
    need = 2 * n * c.readouts
    length(raw) < need &&
        throw(TruncatedFileError("KCD: needs $need bytes for $(c.readouts) readouts"))
    out = zeros(Int32, dims)
    @inbounds for r = 0:(c.readouts-1)
        base = 2 * n * r
        for i = 1:n
            out[i] += Int32(_load_u16(raw, base + 2i - 1))     # little-endian
        end
    end
    return out
end

_fixbyteorder!(A, ::ByteOrder, ::KcdReadouts) = A

"""KCD spells its element type in a `Data type` line; only 16-bit unsigned occurs."""
const KCD_DATA_TYPES = Dict("u16" => UInt16)

function scan(::KCD, src::AbstractSource)
    n = filesize(src)
    n < 32 && throw(TruncatedFileError("KCD: file is too short for a header"))

    h = Header()
    window = min(n, 65536)
    text = String(Char.(bytes(src, 0, window)))
    pos = 1
    lineno = 0
    while pos <= ncodeunits(text)
        nl = findnext('\n', text, pos)
        stop = nl === nothing ? ncodeunits(text) : nl - 1
        line = text[pos:stop]
        lineno += 1
        # "Binned mode" is the one header line with no '=', so it has to be rewritten before
        # the end-of-header test rather than after it. Testing first stops the parse dead
        # there and loses every line below, which on a real file is most of the header.
        strip(line) == "Binned mode" && (line = "Mode = Binned")
        # The header ends at the first line that is over-long or carries no '='; the binary
        # tail has neither property reliably, so both checks are needed.
        (length(line) > 100 || (lineno > 1 && !occursin('=', line))) && break
        if occursin('=', line)
            i = findfirst('=', line)
            key = String(strip(line[1:prevind(line, i)]))
            val = String(strip(line[nextind(line, i):end], ['\0', ' ', '\t', '\r']))
            isempty(key) || (h[key] = val)
        end
        nl === nothing && break
        pos = nl + 1
    end

    d1 = getheader(h, "X dimension", Int, 0)
    d2 = getheader(h, "Y dimension", Int, 0)
    (d1 > 0 && d2 > 0) ||
        throw(CorruptFileError("KCD: missing or nonsensical X/Y dimension ($d1, $d2)"))

    typename = String(getheader(h, "Data type", String, "u16"))
    haskey(KCD_DATA_TYPES, typename) ||
        @warn "KCD: unknown Data type $(repr(typename)); assuming u16"

    readouts = getheader(h, "Number of readouts", Int, 1)
    readouts < 1 && (readouts = 1)

    nbytes = d1 * d2 * 2 * readouts
    nbytes > n &&
        throw(TruncatedFileError("KCD: $(d1)x$(d2) over $readouts readouts needs $nbytes bytes"))

    layout = BinaryLayout{Int32}(
        n - nbytes,                 # the pixels sit at the end of the file
        nbytes,
        (d1, d2);
        byteorder = LittleEndian(),
        codec = KcdReadouts(readouts),
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""
    writekcd(path, A; readouts = 1, extra = Dict())

Write a `.kcd` file. With `readouts` greater than one, `A` is divided evenly between that many
stored readouts so that summing them reproduces it.
"""
function writekcd(
    path::AbstractString,
    A::AbstractArray{<:Integer,2};
    readouts::Int = 1,
    extra = Dict{String,Any}(),
)
    d1, d2 = size(A)
    io = IOBuffer()
    print(io, "Nonius KappaCCD\n")
    print(io, "X dimension = ", d1, "\n")
    print(io, "Y dimension = ", d2, "\n")
    print(io, "Data type = u16\n")
    print(io, "Number of readouts = ", readouts, "\n")
    for (k, v) in extra
        print(io, k, " = ", v, "\n")
    end
    print(io, "End of Header\n")

    # Split each value across the readouts so the sum comes back to A.
    share = [zeros(UInt16, d1, d2) for _ = 1:readouts]
    for i in eachindex(A)
        v = Int(A[i])
        for r = 1:readouts
            part = v ÷ readouts + (r <= v % readouts ? 1 : 0)
            share[r][i] = UInt16(part)
        end
    end
    Base.open(path, "w") do f
        Base.write(f, take!(io))
        for s in share
            Base.write(f, encode(RawBlob(), s))
        end
    end
    return path
end

"""Generic write entry point. See [`writeformat`](@ref)."""
writeformat(fmt::KCD, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone((p, a, _h; kw...) -> writekcd(p, a; kw...), fmt, path, arrays, headers; kwargs...)

"""KCD's shape and readout count. See [`layoutkeys`](@ref)."""
layoutkeys(::KCD) = ("X dimension", "Y dimension", "Data type", "Number of readouts")

"""A KCD file stores unsigned 16-bit readouts, which the reader sums into `Int32`."""
storagetypes(::KCD) = (Int32,)

"""The KCD writer stores integer readouts. See [`narrowstorage`](@ref)."""
coerce(fmt::KCD, A::AbstractArray{<:Any,2}) = narrowstorage(fmt, A)

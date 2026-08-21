"""
    CBF <: ImageFormat

CIF Binary Format: an ASCII CIF header, then a MIME-style binary section holding the pixels,
almost always compressed with [`ByteOffset`](@ref). Written by Pilatus and Eiger detectors and
consumed by essentially every crystallography pipeline.

# On-disk structure

    ###CBF: VERSION 1.5                       ← magic
    …CIF text: `_key value` pairs, and for Pilatus a block of `# key value` comments…
    --CIF-BINARY-FORMAT-SECTION--
    Content-Type: application/octet-stream;
         conversions="x-CBF_BYTE_OFFSET"
    X-Binary-Size: 1234567
    X-Binary-Element-Type: "signed 32-bit integer"
    X-Binary-Size-Fastest-Dimension: 2463
    X-Binary-Size-Second-Dimension: 2527
    …
    <0x0C 0x1A 0x04 0xD5>                     ← binary starter
    …X-Binary-Size bytes of compressed pixels…

The reader locates the starter directly rather than parsing CIF in full. Both the `_key value`
pairs and the MIME headers land in the frame header; Pilatus's `# key value` comment block is
parsed too, since that is where its instrument metadata actually lives.
"""
struct CBF <: ImageFormat end

const CBF_STARTER = UInt8[0x0C, 0x1A, 0x04, 0xD5]
const CBF_SECTION = "--CIF-BINARY-FORMAT-SECTION--"

const CBF_DATA_TYPES = Dict{String,DataType}(
    "signed 8-bit integer" => Int8,
    "signed 16-bit integer" => Int16,
    "signed 32-bit integer" => Int32,
    "signed 64-bit integer" => Int64,
    "unsigned 8-bit integer" => UInt8,
    "unsigned 16-bit integer" => UInt16,
    "unsigned 32-bit integer" => UInt32,
    "unsigned 64-bit integer" => UInt64,
)

const CBF_TYPE_NAMES = Dict{DataType,String}(v => k for (k, v) in CBF_DATA_TYPES)

function scan(::CBF, src::AbstractSource)
    starter = _findbytes(src, CBF_STARTER)
    starter === nothing &&
        throw(CorruptFileError("CBF: binary section starter 0x0C1A04D5 not found"))

    h = Header()
    section = _findbytes(src, Vector{UInt8}(codeunits(CBF_SECTION)))
    textend = section === nothing ? starter : section
    _cbf_parse_cif!(h, String(Char.(bytes(src, 0, textend))))
    if section !== nothing
        _cbf_parse_mime!(h, String(Char.(bytes(src, section, starter - section))))
    end

    fastest = getheader(h, "X-Binary-Size-Fastest-Dimension", Int, 0)
    second = getheader(h, "X-Binary-Size-Second-Dimension", Int, 0)
    (fastest > 0 && second > 0) || throw(
        CorruptFileError(
            "CBF: missing or nonsensical X-Binary-Size-{Fastest,Second}-Dimension " *
            "($fastest, $second)",
        ),
    )
    dims = (fastest, second)          # already (fast, slow), which is Julia's order

    typename = String(getheader(h, "X-Binary-Element-Type", String, "signed 32-bit integer"))
    T = get(CBF_DATA_TYPES, typename, nothing)
    if T === nothing
        @warn "CBF: unknown X-Binary-Element-Type $(repr(typename)); assuming Int32"
        T = Int32
    end

    conversions = uppercase(String(getheader(h, "conversions", String, "X-CBF_BYTE_OFFSET")))
    codec = if occursin("BYTE_OFFSET", conversions)
        ByteOffset()
    elseif occursin("NONE", conversions)
        RawBlob()
    else
        throw(UnsupportedFormatError("CBF compression $(repr(conversions)) is not supported"))
    end

    dataoffset = starter + length(CBF_STARTER)
    nbytes = getheader(h, "X-Binary-Size", Int, 0)
    (nbytes <= 0 || dataoffset + nbytes > filesize(src)) &&
        (nbytes = filesize(src) - dataoffset)
    nbytes <= 0 && throw(TruncatedFileError("CBF: no binary data after the starter"))

    nelem = getheader(h, "X-Binary-Number-of-Elements", Int, prod(dims))
    nelem == prod(dims) || throw(
        CorruptFileError(
            "CBF: X-Binary-Number-of-Elements is $nelem but the dimensions give $(prod(dims))",
        ),
    )

    byteorder =
        occursin("BIG", uppercase(String(getheader(h, "X-Binary-Element-Byte-Order", String, "LITTLE_ENDIAN")))) ?
        BigEndian() : LittleEndian()

    layout = BinaryLayout{T}(
        dataoffset,
        nbytes,
        dims;
        byteorder = byteorder,
        codec = codec,
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""
Parse the CIF text preceding the binary section.

Two kinds of line are captured: CIF data items (`_key value`), and the `# key value` comment
block that Pilatus detectors use, since that is where their instrument metadata actually lives.
A trailing colon is stripped from a comment key, so `# Detector: PILATUS 6M` and
`# Pixel_size 172e-6 m` both land under a bare name.

The comment rule is deliberately mechanical: any comment with two or more whitespace-separated
tokens becomes a header entry, and single-token comments (a bare timestamp, say) are skipped.
That means a line of prose in the comment block becomes a junk entry rather than being guessed
at — predictable, and it never silently drops real metadata. Typed interpretation of these
values belongs with `normalise`, not here.
"""
function _cbf_parse_cif!(h::Header, text::AbstractString)
    for raw in split(text, '\n')
        line = strip(raw)
        isempty(line) && continue
        if startswith(line, '_')
            parts = split(line, limit = 2)
            key = String(parts[1])
            h[key] = length(parts) == 2 ? String(strip(parts[2], [' ', '\t', '\'', '"'])) : ""
        elseif startswith(line, '#')
            body = strip(line, ['#', ' ', '\t'])
            isempty(body) && continue
            parts = split(body, limit = 2)
            length(parts) == 2 || continue
            key = String(rstrip(parts[1], ':'))
            isempty(key) && continue
            h[key] = String(strip(parts[2]))
        end
    end
    return h
end

"""
Parse the MIME-style headers between `--CIF-BINARY-FORMAT-SECTION--` and the binary starter.

Lines are `Key: value`, except the `conversions="…"` continuation of `Content-Type`, which uses
`=`. FabIO splits on `:` and falls back to `=`; this does the same.
"""
function _cbf_parse_mime!(h::Header, text::AbstractString)
    for raw in split(text, '\n')
        line = strip(raw)
        (isempty(line) || startswith(line, "--")) && continue
        i = findfirst(':', line)
        if i === nothing
            i = findfirst('=', line)
            i === nothing && continue
        end
        key = String(strip(line[1:prevind(line, i)]))
        val = String(strip(line[nextind(line, i):end], [' ', '"', '\'', '\r', '\t', ';']))
        isempty(key) && continue
        h[key] = val
    end
    return h
end

"""
    writecbf(path, A, header = Header())

Minimal single-frame CBF writer using the byte-offset codec — enough to round-trip data and to
give the test suite a fixture that needs nothing downloaded. The full writer (MD5, padding,
CIF round-tripping) is Phase 4.
"""
function writecbf(path::AbstractString, A::AbstractArray{T,2}, header::Header = Header()) where {T}
    haskey(CBF_TYPE_NAMES, T) || throw(UnsupportedFormatError("CBF cannot store $T"))
    blob = encode(ByteOffset(), A)
    io = IOBuffer()
    print(io, "###CBF: VERSION 1.5\n\n")
    print(io, "data_fabio_jl\n\n")
    for (k, v) in header
        print(io, k, " ", v, "\n")
    end
    print(io, "\n_array_data.data\n;\n")
    print(io, CBF_SECTION, "\n")
    print(io, "Content-Type: application/octet-stream;\n")
    print(io, "     conversions=\"x-CBF_BYTE_OFFSET\"\n")
    print(io, "Content-Transfer-Encoding: BINARY\n")
    print(io, "X-Binary-Size: ", length(blob), "\n")
    print(io, "X-Binary-ID: 1\n")
    print(io, "X-Binary-Element-Type: \"", CBF_TYPE_NAMES[T], "\"\n")
    print(io, "X-Binary-Element-Byte-Order: LITTLE_ENDIAN\n")
    print(io, "X-Binary-Number-of-Elements: ", length(A), "\n")
    print(io, "X-Binary-Size-Fastest-Dimension: ", size(A, 1), "\n")
    print(io, "X-Binary-Size-Second-Dimension: ", size(A, 2), "\n")
    print(io, "X-Binary-Size-Padding: 0\n\n")
    Base.open(path, "w") do f
        Base.write(f, take!(io))
        Base.write(f, CBF_STARTER)
        Base.write(f, blob)
        Base.write(f, codeunits("\n;\n\n"))
    end
    return path
end

"""Generic write entry point. See [`writeformat`](@ref)."""
writeformat(fmt::CBF, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone(writecbf, fmt, path, arrays, headers; kwargs...)

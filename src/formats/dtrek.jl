"""
    Dtrek <: ImageFormat

The d\\*TREK format, also written by ADSC Quantum detectors — FabIO's `adscimage` is an alias
for its `dtrekimage`, so the two are one reader here too.

# On-disk structure

    {
    HEADER_BYTES=  512;
    DIM=2;
    BYTE_ORDER=little_endian;
    Data_type=unsigned short int;
    SIZE1=3072;
    SIZE2=3072;
    …
    }
    <padding to HEADER_BYTES>
    <raw pixels>

`HEADER_BYTES` is on the second line and gives the offset of the pixel data, so the header can
be read in one go. `SIZE1` is the fast axis and `SIZE2` the slow one, which is already Julia's
order.
"""
struct Dtrek <: ImageFormat end

"""`Data_type` values, as d\\*TREK spells them."""
const DTREK_DATA_TYPES = Dict{String,DataType}(
    "signed char" => Int8,
    "unsigned char" => UInt8,
    "short int" => Int16,
    "unsigned short int" => UInt16,
    "long int" => Int32,
    "unsigned long int" => UInt32,
    "float ieee" => Float32,
)

const DTREK_TYPE_NAMES = Dict{DataType,String}(
    Int8 => "signed char",
    UInt8 => "unsigned char",
    Int16 => "short int",
    UInt16 => "unsigned short int",
    Int32 => "long int",
    UInt32 => "unsigned long int",
    Float32 => "float IEEE",
)

function scan(::Dtrek, src::AbstractSource)
    n = filesize(src)
    n < 16 && throw(TruncatedFileError("d*TREK: file is too short for a header"))
    _byteat(src, 0) == UInt8('{') ||
        throw(CorruptFileError("d*TREK: file does not start with '{'"))

    # HEADER_BYTES sits on the second line and fixes where the pixels begin.
    probe = String(Char.(bytes(src, 0, min(n, 256))))
    m = match(r"HEADER_BYTES\s*=\s*(\d+)"i, probe)
    m === nothing &&
        throw(CorruptFileError("d*TREK: no HEADER_BYTES on the second line"))
    headerbytes = parse(Int, m.captures[1])
    (headerbytes > 0 && headerbytes <= n) || throw(
        TruncatedFileError("d*TREK: HEADER_BYTES is $headerbytes but the file holds $n"),
    )

    h = Header()
    text = String(Char.(bytes(src, 0, headerbytes)))
    for raw in split(text, ';')
        line = strip(raw, ['\0', ' ', '\t', '\r', '\n', '{'])
        isempty(line) && continue
        startswith(line, '}') && break
        i = findfirst('=', line)
        i === nothing && continue
        key = String(strip(line[1:prevind(line, i)]))
        val = String(strip(line[nextind(line, i):end]))
        isempty(key) || (h[key] = val)
    end

    dim = getheader(h, "DIM", Int, 2)
    dim == 2 ||
        throw(UnsupportedFormatError("d*TREK: only 2D images are supported, header says DIM=$dim"))

    d1 = getheader(h, "SIZE1", Int, 0)
    d2 = getheader(h, "SIZE2", Int, 0)
    (d1 > 0 && d2 > 0) ||
        throw(CorruptFileError("d*TREK: missing or zero SIZE1/SIZE2 ($d1, $d2)"))

    T = _dtrek_eltype(h)
    bo = occursin("big", lowercase(String(getheader(h, "BYTE_ORDER", String, "little_endian")))) ?
         BigEndian() : LittleEndian()

    need = d1 * d2 * sizeof(T)
    headerbytes + need > n && throw(
        TruncatedFileError("d*TREK: needs $need bytes of pixels at $headerbytes, file holds $n"),
    )

    layout = BinaryLayout{T}(headerbytes, need, (d1, d2); byteorder = bo, codec = RawBlob())
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

function _dtrek_eltype(h::Header)
    dt = getci(h, "Data_type")
    if dt === nothing
        # Older ADSC files use TYPE instead, and only ever unsigned 16-bit.
        t = getci(h, "TYPE")
        t === nothing ||
            lowercase(strip(String(t))) == "unsigned_short" ||
            @warn "d*TREK: no Data_type and TYPE is $(repr(t)); assuming UInt16"
        return UInt16
    end
    name = lowercase(strip(String(dt)))
    T = get(DTREK_DATA_TYPES, name, nothing)
    T === nothing && throw(
        UnsupportedFormatError("d*TREK: Data_type $(repr(String(dt))) is not supported"),
    )
    return T
end

"""
    writedtrek(path, A, header = Header(); headerbytes = 512, bigendian = false)

Minimal d\\*TREK/ADSC writer, enough to round-trip data and give the tests a fixture.
"""
function writedtrek(
    path::AbstractString,
    A::AbstractArray{T,2},
    header::Header = Header();
    headerbytes::Int = 512,
    bigendian::Bool = false,
) where {T}
    haskey(DTREK_TYPE_NAMES, T) || throw(UnsupportedFormatError("d*TREK cannot store $T"))
    io = IOBuffer()
    print(io, "{\n")
    print(io, "HEADER_BYTES=", lpad(headerbytes, 5), ";\n")
    print(io, "DIM=2;\n")
    print(io, "BYTE_ORDER=", bigendian ? "big_endian" : "little_endian", ";\n")
    print(io, "Data_type=", DTREK_TYPE_NAMES[T], ";\n")
    print(io, "SIZE1=", size(A, 1), ";\n")
    print(io, "SIZE2=", size(A, 2), ";\n")
    for (k, v) in header
        print(io, k, "=", v, ";\n")
    end
    print(io, "}\n")
    block = take!(io)
    length(block) <= headerbytes ||
        throw(ArgumentError("d*TREK header needs $(length(block)) bytes, more than headerbytes=$headerbytes"))
    payload =
        bigendian != (NativeByteOrder === BigEndian) ?
        Vector{UInt8}(reinterpret(UInt8, bswap.(vec(collect(A))))) : encode(RawBlob(), A)
    Base.open(path, "w") do f
        Base.write(f, block)
        Base.write(f, zeros(UInt8, headerbytes - length(block)))
        Base.write(f, payload)
    end
    return path
end

"""Generic write entry point. See [`writeformat`](@ref)."""
writeformat(fmt::Dtrek, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeone(writedtrek, fmt, path, arrays, headers; kwargs...)

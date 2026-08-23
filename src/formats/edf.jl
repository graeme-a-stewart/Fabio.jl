"""
    EDF <: ImageFormat

The ESRF Data Format: one or more frames, each an ASCII header of `key = value;` pairs
enclosed in braces, followed immediately by a binary blob.

EDF is the reference format for this package because it exercises nearly every axis of the
design at once — multiple frames per file, a per-frame header, either byte order, an optional
zlib-compressed blob, a file-level "general block", and `.gz` container compression.

A frame whose header carries `EDF_DataFormatVersion` is a *general block*: file-level metadata
with no pixels, merged underneath every subsequent frame's header.
"""
struct EDF <: ImageFormat end

"""EDF `DataType` values, as written by the various producers, mapped to Julia types."""
const EDF_DATA_TYPES = Dict{String,DataType}(
    "SIGNEDBYTE" => Int8,
    "SIGNED8" => Int8,
    "UNSIGNEDBYTE" => UInt8,
    "UNSIGNED8" => UInt8,
    "SIGNEDSHORT" => Int16,
    "SIGNED16" => Int16,
    "UNSIGNEDSHORT" => UInt16,
    "UNSIGNED16" => UInt16,
    "UNSIGNEDSHORTINTEGER" => UInt16,
    "SIGNEDINTEGER" => Int32,
    "SIGNED32" => Int32,
    "UNSIGNEDINTEGER" => UInt32,
    "UNSIGNED32" => UInt32,
    "SIGNEDLONG" => Int32,
    "UNSIGNEDLONG" => UInt32,
    "SIGNED64" => Int64,
    "UNSIGNED64" => UInt64,
    "FLOATVALUE" => Float32,
    "FLOAT" => Float32,
    "FLOATIEEE32" => Float32,
    "FLOAT32" => Float32,
    "DOUBLE" => Float64,
    "DOUBLEVALUE" => Float64,
    "FLOATIEEE64" => Float64,
    "DOUBLEIEEE64" => Float64,
)

const EDF_TYPE_NAMES = Dict{DataType,String}(
    Int8 => "SignedByte",
    UInt8 => "UnsignedByte",
    Int16 => "SignedShort",
    UInt16 => "UnsignedShort",
    Int32 => "SignedInteger",
    UInt32 => "UnsignedInteger",
    Int64 => "Signed64",
    UInt64 => "Unsigned64",
    Float32 => "FloatValue",
    Float64 => "DoubleValue",
)

const _EDF_SPACE = (0x20, 0x0A, 0x0D, 0x09, 0x00)

"""
Locate one EDF header block starting at or after `pos`.

Returns `(textstart, textstop, dataoffset)` with the header text in `[textstart, textstop)` and
the binary blob beginning at `dataoffset`, or `nothing` at a clean end of file.
"""
function _edf_findblock(src::AbstractSource, pos::Integer)
    n = filesize(src)
    p = Int(pos)
    while p < n && _byteat(src, p) in _EDF_SPACE
        p += 1
    end
    p >= n && return nothing
    _byteat(src, p) == UInt8('{') ||
        throw(CorruptFileError("EDF: expected '{' at byte $p, found $(repr(Char(_byteat(src, p))))"))
    start = p + 1
    q = start
    while q < n
        if _byteat(src, q) == UInt8('}')
            if q + 1 < n && _byteat(src, q + 1) == 0x0A
                return (start, q, q + 2)
            elseif q + 2 < n && _byteat(src, q + 1) == 0x0D && _byteat(src, q + 2) == 0x0A
                return (start, q, q + 3)
            end
        end
        q += 1
    end
    throw(TruncatedFileError("EDF: header block starting at byte $pos is never closed"))
end

function _edf_parseheader(src::AbstractSource, textstart::Int, textstop::Int)
    text = String(Char.(bytes(src, textstart, textstop - textstart)))
    h = Header()
    for line in split(text, ';')
        i = findfirst('=', line)
        i === nothing && continue
        key = strip(line[1:prevind(line, i)], ['\0', ' ', '\t', '\r', '\n'])
        val = strip(line[nextind(line, i):end], ['\0', ' ', '\t', '\r', '\n'])
        isempty(key) && continue
        h[String(key)] = String(val)
    end
    return h
end

function _edf_codec(h::Header)
    c = uppercase(String(getheader(h, "Compression", String, "NONE")))
    (isempty(c) || c == "NONE") && return RawBlob()
    (c == "ZLIB" || c == "GZIP" || c == "DEFLATE") && return ZlibBlob()
    throw(UnsupportedFormatError("EDF compression $(repr(c)) is not supported yet"))
end

function _edf_eltype(h::Header)
    name = uppercase(strip(String(getheader(h, "DataType", String, "UnsignedShort"))))
    T = get(EDF_DATA_TYPES, name, nothing)
    T === nothing && throw(CorruptFileError("EDF: unknown DataType $(repr(name))"))
    return T
end

function _edf_byteorder(h::Header)
    bo = uppercase(String(getheader(h, "ByteOrder", String, "LowByteFirst")))
    startswith(bo, "HIGH") ? BigEndian() : LittleEndian()
end

function scan(::EDF, src::AbstractSource)
    fileheader = Header()
    specs = FrameSpec[]
    pos = 0
    n = filesize(src)

    while pos < n
        block = _edf_findblock(src, pos)
        block === nothing && break
        textstart, textstop, dataoffset = block
        h = _edf_parseheader(src, textstart, textstop)

        if haskey(h, "EDF_DataFormatVersion")
            # A general block: file-level metadata, no pixels.
            merge!(fileheader, h)
            pos = dataoffset + getheader(h, "EDF_BinarySize", Int, 0)
            continue
        end

        T = _edf_eltype(h)
        codec = _edf_codec(h)
        d1 = getheader(h, "Dim_1", Int)
        d2 = getheader(h, "Dim_2", Int)
        (d1 > 0 && d2 > 0) || throw(CorruptFileError("EDF: nonsensical Dim_1/Dim_2 ($d1, $d2)"))
        dims = (d1, d2)                    # Dim_1 is the fast axis, as in Julia order

        nbytes = getheader(h, "EDF_BinarySize", Int, 0)
        nbytes == 0 && (nbytes = getheader(h, "Size", Int, 0))
        nbytes == 0 && (nbytes = d1 * d2 * sizeof(T))

        if dataoffset + nbytes > n
            throw(
                TruncatedFileError(
                    "EDF: frame $(length(specs) + 1) declares $nbytes bytes at offset " *
                    "$dataoffset but the file holds $n",
                ),
            )
        end

        layout = BinaryLayout{T}(
            dataoffset,
            nbytes,
            dims;
            byteorder = _edf_byteorder(h),
            codec = codec,
        )
        push!(specs, FrameSpec(h, layout))
        pos = dataoffset + nbytes
    end

    isempty(specs) && throw(CorruptFileError("EDF: no frames found"))
    return fileheader, specs
end

# Tolerant scanning: keep whatever frames were complete. Used by `openimage(...; strict=false)`
# for files a detector is still writing.
function _partialscan(fmt::EDF, src::AbstractSource)
    fileheader = Header()
    specs = FrameSpec[]
    pos = 0
    n = filesize(src)
    try
        while pos < n
            block = _edf_findblock(src, pos)
            block === nothing && break
            textstart, textstop, dataoffset = block
            h = _edf_parseheader(src, textstart, textstop)
            if haskey(h, "EDF_DataFormatVersion")
                merge!(fileheader, h)
                pos = dataoffset + getheader(h, "EDF_BinarySize", Int, 0)
                continue
            end
            T = _edf_eltype(h)
            d1 = getheader(h, "Dim_1", Int)
            d2 = getheader(h, "Dim_2", Int)
            nbytes = getheader(h, "EDF_BinarySize", Int, 0)
            nbytes == 0 && (nbytes = getheader(h, "Size", Int, 0))
            nbytes == 0 && (nbytes = d1 * d2 * sizeof(T))
            dataoffset + nbytes > n && break
            push!(
                specs,
                FrameSpec(
                    h,
                    BinaryLayout{T}(
                        dataoffset,
                        nbytes,
                        (d1, d2);
                        byteorder = _edf_byteorder(h),
                        codec = _edf_codec(h),
                    ),
                ),
            )
            pos = dataoffset + nbytes
        end
    catch
        # Whatever we have is what the file actually contains.
    end
    return (fileheader, specs)
end
"""
    edfheadertext(A, header=Header(); kwargs...) -> String

Build the ASCII header block for one EDF frame, padded to a multiple of `padto` bytes as
readers expect.

The fields, and their order, are the ones FabIO writes, so a file from here is a file of the
kind FabIO produces: `EDF_DataBlockID`, `EDF_BinarySize`, `EDF_HeaderSize`, `ByteOrder`,
`DataType`, `Dim_1`, `Dim_2`, `Image`, `HeaderID`, `Size`, and then whatever else the caller
supplied.

- `index` - 0-based frame number, which appears in three of those fields
- `binarysize` - bytes of stored data, which is not `length(A) * sizeof(T)` once compressed
- `compression` - `:none` or `:zlib`

`EDF_HeaderSize` states the size of the block it sits inside, so it is written in a
fixed-width field whose value is worked out from the lengths either side of it rather than by
searching the finished text for a placeholder.
"""
function edfheadertext(
    A::AbstractArray{T,2},
    header::Header = Header();
    padto::Int = 512,
    byteorder::ByteOrder = NativeByteOrder(),
    index::Integer = 0,
    binarysize::Integer = length(A) * sizeof(T),
    compression::Symbol = :none,
) where {T}
    haskey(EDF_TYPE_NAMES, T) || throw(UnsupportedFormatError("EDF cannot store $T"))
    compression in (:none, :zlib) ||
        throw(UnsupportedFormatError("EDF compression $(repr(compression)) is not supported"))

    head = IOBuffer()
    print(head, "{\n")
    print(head, "EDF_DataBlockID = ", index, ".Image.Psd ;\n")
    print(head, "EDF_BinarySize = ", binarysize, " ;\n")
    print(head, "EDF_HeaderSize = ")
    prefix = String(take!(head))

    tail = IOBuffer()
    print(tail, " ;\n")
    print(tail, "ByteOrder = ", byteorder isa LittleEndian ? "LowByteFirst" : "HighByteFirst", " ;\n")
    print(tail, "DataType = ", EDF_TYPE_NAMES[T], " ;\n")
    print(tail, "Dim_1 = ", size(A, 1), " ;\n")
    print(tail, "Dim_2 = ", size(A, 2), " ;\n")
    compression === :none || print(tail, "Compression = Zlib ;\n")
    print(tail, "Image = ", index, " ;\n")
    print(tail, "HeaderID = EH:", lpad(index, 6, '0'), ":000000:000000 ;\n")
    print(tail, "Size = ", binarysize, " ;\n")
    # The keys above are generated from the array, so a caller's stale copy of them must not
    # follow: EDF has no notion of a duplicate key, the reader keeps the last one seen, and a
    # header carried over from a differently shaped file would otherwise describe this one.
    for (k, v) in striplayoutkeys(EDF(), header)
        print(tail, k, " = ", v, " ;\n")
    end
    rest = String(take!(tail))

    # The closing brace and newline must fall on the padding boundary, and the size field is a
    # fixed width, so the total is known before the number is written into it.
    fixed = length(prefix) + EDF_HEADERSIZE_WIDTH + length(rest) + 2
    total = fixed + mod(-fixed, padto)
    return prefix *
           lpad(total, EDF_HEADERSIZE_WIDTH) *
           rest *
           " "^(total - fixed) *
           "}\n"
end

"""Width of the `EDF_HeaderSize` field, wide enough for any header a detector writes."""
const EDF_HEADERSIZE_WIDTH = 8

"""
    writeedf(path, A, header=Header(); compression=:none, byteorder=..., padto=512)
    writeedf(path, arrays, headers=...; compression=:none, byteorder=..., padto=512)

Write an EDF file, of one frame or many.

EDF is a sequence of independent `{ header } data` blocks, which is why a multi-frame file
needs nothing more than writing several of them: the reader walks from one to the next using
each block's own `EDF_BinarySize`.

`compression = :zlib` deflates each frame's data and records `Compression = Zlib`. FabIO
cannot do this - its `EdfImage.write` takes no compression argument and its source never
mentions one - though its reader handles such files, so what this writes stays readable there.
"""
function writeedf(
    path::AbstractString,
    arrays::AbstractVector,
    headers::AbstractVector = [Header() for _ in arrays];
    compression::Symbol = :none,
    byteorder::ByteOrder = NativeByteOrder(),
    padto::Int = 512,
)
    isempty(arrays) && throw(ArgumentError("writeedf needs at least one frame"))
    length(headers) == length(arrays) ||
        throw(ArgumentError("got $(length(arrays)) frames and $(length(headers)) headers"))
    Base.open(path, "w") do io
        for (i, A) in enumerate(arrays)
            raw = encode(RawBlob(), A)
            blob = compression === :zlib ? transcode(ZlibCompressor, raw) : raw
            text = edfheadertext(
                A,
                headers[i];
                padto = padto,
                byteorder = byteorder,
                index = i - 1,
                binarysize = length(blob),
                compression = compression,
            )
            Base.write(io, codeunits(text))
            Base.write(io, blob)
        end
    end
    return path
end

writeedf(path::AbstractString, A::AbstractArray{<:Any,2}, header::Header = Header(); kwargs...) =
    writeedf(path, [A], [header]; kwargs...)

"""Generic write entry point. EDF is natively multi-frame. See [`writeformat`](@ref)."""
writeformat(::EDF, path::AbstractString, arrays::AbstractVector, headers::AbstractVector; kwargs...) =
    writeedf(path, arrays, collect(Header, headers); kwargs...)

"""The keys `writeedf` generates from the array itself. See [`layoutkeys`](@ref)."""
layoutkeys(::EDF) = (
    "HeaderID", "ByteOrder", "DataType", "Dim_1", "Dim_2", "Size", "Compression",
    "EDF_BinarySize", "EDF_HeaderSize", "EDF_DataBlockID", "Image",
)

"""EDF stores every type this package knows. See [`storagetypes`](@ref)."""
storagetypes(::EDF) = Tuple(sort!(collect(keys(EDF_TYPE_NAMES)); by = string))

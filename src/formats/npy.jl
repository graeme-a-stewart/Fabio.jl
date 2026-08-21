"""
    NPY <: ImageFormat

NumPy's own `.npy` container.

Worth having in the core for two reasons: it is the lingua franca for handing arrays between
Python and Julia, and it is the simplest possible tier-1 format, which makes it a good
reference when writing a new one.

It is also the one format where the file itself states its memory order. A C-ordered `.npy`
of numpy shape `(rows, cols)` is stored exactly as a Julia `(cols, rows)` array — the same
identity that motivates this package's fast-axis-first convention — so it maps in with no
permutation at all. A Fortran-ordered file maps in directly as `(rows, cols)`.
"""
struct NPY <: ImageFormat end

const NPY_MAGIC = UInt8[0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]   # \x93NUMPY

const NPY_DTYPES = Dict{String,DataType}(
    "b1" => Bool,
    "i1" => Int8,
    "u1" => UInt8,
    "i2" => Int16,
    "u2" => UInt16,
    "i4" => Int32,
    "u4" => UInt32,
    "i8" => Int64,
    "u8" => UInt64,
    "f4" => Float32,
    "f8" => Float64,
)

const NPY_DESCRS = Dict{DataType,String}(
    Bool => "|b1",
    Int8 => "|i1",
    UInt8 => "|u1",
    Int16 => "<i2",
    UInt16 => "<u2",
    Int32 => "<i4",
    UInt32 => "<u4",
    Int64 => "<i8",
    UInt64 => "<u8",
    Float32 => "<f4",
    Float64 => "<f8",
)

function scan(::NPY, src::AbstractSource)
    n = filesize(src)
    n < 10 && throw(TruncatedFileError("NPY: file is too short to hold a header"))
    head = bytes(src, 0, 10)
    @views head[1:6] == NPY_MAGIC || throw(CorruptFileError("NPY: bad magic"))
    major = head[7]

    headerlen, dataoffset = if major == 0x01
        (Int(_load_u16(head, 9)), 10)
    else
        (Int(_load_u32(bytes(src, 8, 4), 1)), 12)
    end
    dataoffset + headerlen > n &&
        throw(TruncatedFileError("NPY: declared header of $headerlen bytes runs past the file"))

    text = String(Char.(bytes(src, dataoffset, headerlen)))
    descr = _npy_field(text, "descr")
    fortran = _npy_field(text, "fortran_order") == "True"
    shape = _npy_shape(text)

    length(shape) == 2 ||
        throw(UnsupportedFormatError("NPY: only 2D arrays are supported, got shape $shape"))

    T = get(NPY_DTYPES, descr[end-1:end], nothing)
    T === nothing && throw(UnsupportedFormatError("NPY: unsupported dtype $(repr(descr))"))
    bo = descr[1] == '>' ? BigEndian() : LittleEndian()

    # numpy shape is (slow, fast) for C order and (fast, slow) for Fortran order; either way
    # we want the axis that varies fastest in memory first.
    dims = fortran ? (shape[1], shape[2]) : (shape[2], shape[1])

    h = Header()
    h["descr"] = descr
    h["fortran_order"] = fortran
    h["shape"] = shape

    payload = dataoffset + headerlen
    layout = BinaryLayout{T}(
        payload,
        n - payload,
        dims;
        byteorder = bo,
        codec = RawBlob(),
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

function _npy_field(text::AbstractString, key::AbstractString)
    m = match(Regex("'" * key * "'\\s*:\\s*'?([^,'}]+)'?"), text)
    m === nothing && throw(CorruptFileError("NPY: header has no '$key' field"))
    return strip(String(m.captures[1]))
end

function _npy_shape(text::AbstractString)
    m = match(r"'shape'\s*:\s*\(([^)]*)\)", text)
    m === nothing && throw(CorruptFileError("NPY: header has no 'shape' field"))
    parts = filter(!isempty, strip.(split(String(m.captures[1]), ',')))
    return Tuple(parse(Int, p) for p in parts)
end

"""
    writenpy(path, A)

Write a 2D array as a Fortran-ordered `.npy` file — no permutation, since that is already
Julia's memory order. numpy reads it back with `numpy.load` and `shape == size(A)`.
"""
function writenpy(path::AbstractString, A::AbstractArray{T,2}) where {T}
    haskey(NPY_DESCRS, T) || throw(UnsupportedFormatError("NPY cannot store $T"))
    dict = "{'descr': '$(NPY_DESCRS[T])', 'fortran_order': True, 'shape': ($(size(A,1)), $(size(A,2))), }"
    # Total header length must be a multiple of 64 bytes.
    len = 10 + length(dict) + 1
    pad = mod(-len, 64)
    dict = dict * " "^pad * "\n"
    Base.open(path, "w") do io
        Base.write(io, NPY_MAGIC)
        Base.write(io, UInt8(1), UInt8(0))
        Base.write(io, htol(UInt16(length(dict))))
        Base.write(io, codeunits(dict))
        Base.write(io, encode(RawBlob(), A))
    end
    return path
end

"""Generic write entry point. NumPy carries no header of its own. See [`writeformat`](@ref)."""
writeformat(fmt::NPY, path::AbstractString, arrays::AbstractVector, headers::AbstractVector) =
    writeone((p, a, _h) -> writenpy(p, a), fmt, path, arrays, headers)

"""The three fields of a `.npy` header, all describing the buffer. See [`layoutkeys`](@ref)."""
layoutkeys(::NPY) = ("descr", "fortran_order", "shape")

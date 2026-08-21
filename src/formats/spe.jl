"""
    SPE <: ImageFormat

Princeton Instruments / WinSpec `.spe` frames. Multi-frame: a fixed 4100-byte header, then
`num_frames` images back to back.

# On-disk structure

    byte    10   exposure time, Float32
    byte    20   acquisition date, 9 ASCII bytes
    byte    42   x_dim, Int16              (the fast axis)
    byte    72   centre wavelength, Float32
    byte   108   data_type, UInt16         0 Float32, 1 Int32, 2 Int16, 3 UInt16
    byte   172   acquisition time, 6 ASCII bytes
    byte   650   grating, Float32
    byte   656   y_dim, Int16              (the slow axis)
    byte   678   xml_offset, Int64         zero for version 2, otherwise version 3
    byte  1446   num_frames, Int32
    byte  4100   the frames

Everything is little-endian.

# Versions

A zero at byte 678 means version 2, where all metadata lives in the fixed header. A non-zero
value is the offset of an XML footer holding version 3's much richer metadata. That footer is
captured verbatim as the `xml` header entry rather than parsed: it would need an XML dependency,
and the fields FabIO extracts from it — region of interest, detector name, grating, wavelength —
are a small selection of what it contains. The pixel data is read identically either way.
"""
struct SPE <: ImageFormat end

const SPE_HEADER_BYTES = 4100

"""`data_type` codes, as WinSpec writes them."""
const SPE_DATA_TYPES = Dict{Int,DataType}(
    0 => Float32,
    1 => Int32,
    2 => Int16,
    3 => UInt16,
)

function scan(::SPE, src::AbstractSource)
    n = filesize(src)
    n < SPE_HEADER_BYTES &&
        throw(TruncatedFileError("SPE: file is shorter than its 4100-byte header"))
    raw = bytes(src, 0, SPE_HEADER_BYTES)

    i16(off) = Int(reinterpret(Int16, _load_u16(raw, off + 1)))
    i32(off) = Int(_load_i32(raw, off + 1))
    f32(off) = Float64(reinterpret(Float32, _load_i32(raw, off + 1)))
    ascii(off, len) = strip(String(Char.(@view raw[(off+1):(off+len)])), ['\0', ' '])

    xmloffset = Int(_load_i64(raw, 679))
    version = xmloffset == 0 ? 2 : 3

    d1 = i16(42)
    d2 = i16(656)
    (d1 > 0 && d2 > 0) || throw(CorruptFileError("SPE: nonsensical x_dim/y_dim ($d1, $d2)"))

    code = Int(_load_u16(raw, 109))
    T = get(SPE_DATA_TYPES, code, nothing)
    T === nothing && throw(UnsupportedFormatError("SPE: data_type $code is not supported"))

    h = Header()
    h["version"] = version
    h["x_dim"] = d1
    h["y_dim"] = d2
    h["data_type"] = code
    h["exposure_time"] = f32(10)
    h["center_wavelength"] = f32(72)
    h["grating"] = f32(650)
    h["date"] = ascii(20, 9)
    h["time"] = ascii(172, 6)
    h["xml_offset"] = xmloffset

    nframes = i32(1446)
    framebytes = d1 * d2 * sizeof(T)
    available = (version == 3 && xmloffset > SPE_HEADER_BYTES ? xmloffset : n) - SPE_HEADER_BYTES
    available > 0 || throw(TruncatedFileError("SPE: no pixel data after the header"))
    fits = available ÷ framebytes
    if nframes <= 0
        nframes = max(fits, 1)
    elseif nframes > fits
        @warn "SPE: header claims $nframes frames but only $fits fit; reading those" file =
            sourcepath(src)
        nframes = fits
    end
    nframes >= 1 || throw(TruncatedFileError("SPE: not even one $(d1)x$(d2) frame fits"))
    h["num_frames"] = nframes

    if version == 3 && xmloffset > 0 && xmloffset < n
        h["xml"] = String(Char.(bytes(src, xmloffset, n - xmloffset)))
    end

    specs = FrameSpec[]
    for k = 0:(nframes-1)
        fh = copy(h)
        fh["FrameIndex"] = k + 1
        push!(
            specs,
            FrameSpec(
                fh,
                BinaryLayout{T}(
                    SPE_HEADER_BYTES + k * framebytes,
                    framebytes,
                    (d1, d2);
                    byteorder = LittleEndian(),
                    codec = RawBlob(),
                ),
            ),
        )
    end
    return Header(), specs
end

"""
    writespe(path, frames; exposure = 0.0, date = "", time = "")

Write a version-2 SPE stack from a vector of same-sized arrays (or one array).
"""
writespe(path::AbstractString, A::AbstractArray{<:Any,2}; kwargs...) = writespe(path, [A]; kwargs...)

function writespe(
    path::AbstractString,
    frames::AbstractVector{<:AbstractArray{T,2}};
    exposure::Real = 0.0,
    date::AbstractString = "",
    time::AbstractString = "",
) where {T}
    isempty(frames) && throw(ArgumentError("writespe needs at least one frame"))
    code = findfirst(==(T), SPE_DATA_TYPES)
    code === nothing && throw(UnsupportedFormatError("SPE cannot store $T"))
    d1, d2 = size(first(frames))
    all(f -> size(f) == (d1, d2), frames) ||
        throw(ArgumentError("all SPE frames must be the same size"))

    hdr = zeros(UInt8, SPE_HEADER_BYTES)
    put16(off, v) = (hdr[(off+1):(off+2)] = reinterpret(UInt8, [htol(UInt16(v))]))
    put32(off, v) = (hdr[(off+1):(off+4)] = reinterpret(UInt8, [htol(Int32(v))]))
    putf32(off, v) = (hdr[(off+1):(off+4)] = reinterpret(UInt8, [htol(Float32(v))]))
    putstr(off, s, len) = (b = Vector{UInt8}(codeunits(rpad(s, len)))[1:len];
                           hdr[(off+1):(off+len)] = b)
    put16(0, 2)                 # ControllerVersion, which real files never leave at zero
    putf32(10, exposure)
    isempty(date) || putstr(20, date, 9)
    put16(42, d1)
    put16(108, code)
    isempty(time) || putstr(172, time, 6)
    put16(656, d2)
    # byte 678 stays zero, marking version 2
    put32(1446, length(frames))

    Base.open(path, "w") do f
        Base.write(f, hdr)
        for A in frames
            Base.write(f, encode(RawBlob(), A))
        end
    end
    return path
end

"""Generic write entry point. SPE is natively multi-frame. See [`writeformat`](@ref)."""
writeformat(::SPE, path::AbstractString, arrays::AbstractVector, ::AbstractVector; kwargs...) =
    writespe(path, arrays; kwargs...)

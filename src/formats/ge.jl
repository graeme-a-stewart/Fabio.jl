"""
    GE <: ImageFormat

General Electric / GE Angio detector frames, as used at APS. Multi-frame: a fixed binary
header, then `NumberOfFrames` images of `NumberOfRowsInFrame`×`NumberOfColsInFrame` pixels.

# On-disk structure

    byte 0   a fixed little-endian struct: an ASCII format tag, then the header sizes,
             the frame count, the frame dimensions and the pixel depth
    …        the standard header runs to `StandardHeaderSizeInBytes`
    …        a user header of `UserHeaderSizeInBytes` follows it
    …        the frames, back to back

# Blanked headers

A firmware update at APS began writing the header as zeros. FabIO handles this by recognising
the blanked case and substituting known values — an 8192-byte header, 2048² frames of 16-bit
pixels — and deriving the frame count from the file size. This reader does the same, and
records `HeaderBlanked` in the header so a caller can tell that the geometry was assumed rather
than read.
"""
struct GE <: ImageFormat end

const GE_DEFAULT_HEADER_BYTES = 8192
const GE_DEFAULT_ROWS = 2048
const GE_DEFAULT_COLS = 2048
const GE_DEFAULT_DEPTH = 16

# offset (0-based), name, byte width; all integers little-endian
const GE_FIELDS = (
    (10, "VersionOfStandardHeader", 2),
    (12, "StandardHeaderSizeInBytes", 4),
    (16, "VersionOfUserHeader", 2),
    (18, "UserHeaderSizeInBytes", 4),
    (22, "NumberOfFrames", 2),
    (24, "NumberOfRowsInFrame", 2),
    (26, "NumberOfColsInFrame", 2),
    (28, "ImageDepthInBits", 2),
)

const GE_DEPTH_TYPES = Dict(8 => UInt8, 16 => UInt16, 32 => UInt32)

function scan(::GE, src::AbstractSource)
    n = filesize(src)
    n < 64 && throw(TruncatedFileError("GE: file is too short for a header"))
    raw = bytes(src, 0, min(n, 64))

    h = Header()
    h["ImageFormat"] = strip(String(Char.(bytes(src, 0, 10))), ['\0', ' '])
    for (off, name, width) in GE_FIELDS
        h[name] = width == 2 ? Int(_load_u16(raw, off + 1)) : Int(_load_u32(raw, off + 1))
    end

    stdsize = h["StandardHeaderSizeInBytes"]
    usrsize = h["UserHeaderSizeInBytes"]
    rows = h["NumberOfRowsInFrame"]
    cols = h["NumberOfColsInFrame"]
    depth = h["ImageDepthInBits"]
    nframes = h["NumberOfFrames"]

    blanked = stdsize == 0 || rows == 0 || cols == 0 || depth == 0
    if blanked
        # The APS firmware writes zeros here; fall back to the known detector geometry.
        stdsize = GE_DEFAULT_HEADER_BYTES
        usrsize = 0
        rows = GE_DEFAULT_ROWS
        cols = GE_DEFAULT_COLS
        depth = GE_DEFAULT_DEPTH
        h["StandardHeaderSizeInBytes"] = stdsize
        h["UserHeaderSizeInBytes"] = usrsize
        h["NumberOfRowsInFrame"] = rows
        h["NumberOfColsInFrame"] = cols
        h["ImageDepthInBits"] = depth
        nframes = 0                       # recomputed from the file size below
    end
    h["HeaderBlanked"] = blanked

    T = get(GE_DEPTH_TYPES, depth, nothing)
    T === nothing &&
        throw(UnsupportedFormatError("GE: ImageDepthInBits=$depth is not 8, 16 or 32"))

    dataoffset = stdsize + usrsize
    framebytes = rows * cols * sizeof(T)
    framebytes > 0 || throw(CorruptFileError("GE: zero-sized frames"))
    available = n - dataoffset
    available > 0 ||
        throw(TruncatedFileError("GE: header of $dataoffset bytes leaves no room for pixels"))

    fits = available ÷ framebytes
    if nframes <= 0
        nframes = fits
    elseif nframes > fits
        @warn "GE: header claims $nframes frames but only $fits fit; reading those" file =
            sourcepath(src)
        nframes = fits
    end
    nframes >= 1 || throw(TruncatedFileError("GE: not even one $(cols)x$(rows) frame fits"))
    h["NumberOfFrames"] = nframes

    specs = FrameSpec[]
    for k = 0:(nframes-1)
        fh = copy(h)
        fh["FrameIndex"] = k + 1
        push!(
            specs,
            FrameSpec(
                fh,
                BinaryLayout{T}(
                    dataoffset + k * framebytes,
                    framebytes,
                    (cols, rows);          # NumberOfColsInFrame is the fast axis
                    byteorder = LittleEndian(),
                    codec = RawBlob(),
                ),
            ),
        )
    end
    return Header(), specs
end

"""
    writege(path, frames; headerbytes = 8192, blanked = false)

Write a GE stack from a vector of same-sized arrays (or one array). `blanked = true` zeroes the
header the way the APS firmware does, so the fallback path can be tested.
"""
writege(path::AbstractString, A::AbstractArray{<:Any,2}; kwargs...) = writege(path, [A]; kwargs...)

function writege(
    path::AbstractString,
    frames::AbstractVector{<:AbstractArray{T,2}};
    headerbytes::Int = GE_DEFAULT_HEADER_BYTES,
    blanked::Bool = false,
) where {T}
    isempty(frames) && throw(ArgumentError("writege needs at least one frame"))
    depth = findfirst(==(T), GE_DEPTH_TYPES)
    depth === nothing && throw(UnsupportedFormatError("GE cannot store $T"))
    cols, rows = size(first(frames))
    all(f -> size(f) == (cols, rows), frames) ||
        throw(ArgumentError("all GE frames must be the same size"))

    hdr = zeros(UInt8, headerbytes)
    if !blanked
        hdr[1:10] = Vector{UInt8}(codeunits(rpad("ADEPT", 10)))   # the tag GE writes
        put16(off, v) = (hdr[(off+1):(off+2)] = reinterpret(UInt8, [htol(UInt16(v))]))
        put32(off, v) = (hdr[(off+1):(off+4)] = reinterpret(UInt8, [htol(UInt32(v))]))
        put16(10, 1)
        put32(12, headerbytes)
        put16(16, 1)
        put32(18, 0)
        put16(22, length(frames))
        put16(24, rows)
        put16(26, cols)
        put16(28, depth)
    end
    Base.open(path, "w") do f
        Base.write(f, hdr)
        for A in frames
            Base.write(f, encode(RawBlob(), A))
        end
    end
    return path
end

"""
    MRC <: ImageFormat

MRC / CCP4 map files, the electron-microscopy and volume format. Naturally multi-frame: `NZ`
sections of `NX`×`NY` pixels, all the same type, stored back to back.

# On-disk structure

    word 1..56   the header, as Int32 or Float32 depending on the field
    byte 224     ten 80-character text labels
    byte 1024    NSYMBT bytes of extended header
    …            NZ sections of NX x NY pixels

`NX` is the fast axis, which is already Julia's order. `MODE` selects the pixel type.

# A divergence from FabIO

FabIO names only the first 30 header words and reads all of them as `Int32`. Both are wrong
against the MRC2014 specification: the cell dimensions and angles, the density statistics, the
origin and `RMS` are `Float32`, and the `MAP` stamp is word 53, not word 27. FabIO's own check
that `MAP` reads back as `"MAP "` therefore never succeeds — it logs at info level and carries
on. This reader follows the specification, so header values are physically meaningful, and the
byte order is taken from the `MACHST` stamp where it is set.
"""
struct MRC <: ImageFormat end

const MRC_HEADER_BYTES = 1024

"""`MODE` values this reader understands. Complex modes 3 and 4 have no single-channel meaning."""
const MRC_MODES = Dict{Int,DataType}(
    0 => Int8,
    1 => Int16,
    2 => Float32,
    6 => UInt16,
    12 => Float16,
)

"""Header words that are `Float32` rather than `Int32`, by 1-based word number (MRC2014)."""
const MRC_FLOAT_WORDS = Set([11, 12, 13, 14, 15, 16, 20, 21, 22, 50, 51, 52, 55])

"""Names for the header words this reader exposes, by 1-based word number."""
const MRC_WORD_NAMES = Dict(
    1 => "NX", 2 => "NY", 3 => "NZ", 4 => "MODE",
    5 => "NXSTART", 6 => "NYSTART", 7 => "NZSTART",
    8 => "MX", 9 => "MY", 10 => "MZ",
    11 => "CELL_A", 12 => "CELL_B", 13 => "CELL_C",
    14 => "CELL_ALPHA", 15 => "CELL_BETA", 16 => "CELL_GAMMA",
    17 => "MAPC", 18 => "MAPR", 19 => "MAPS",
    20 => "DMIN", 21 => "DMAX", 22 => "DMEAN",
    23 => "ISPG", 24 => "NSYMBT",
    50 => "ORIGIN_X", 51 => "ORIGIN_Y", 52 => "ORIGIN_Z",
    54 => "MACHST", 55 => "RMS", 56 => "NLABL",
)

function scan(::MRC, src::AbstractSource)
    n = filesize(src)
    n < MRC_HEADER_BYTES &&
        throw(TruncatedFileError("MRC: file is shorter than its 1024-byte header"))
    raw = bytes(src, 0, MRC_HEADER_BYTES)

    be = _mrc_bigendian(raw)
    word(i) = be ? bswap(_load_i32(raw, 4 * (i - 1) + 1)) : _load_i32(raw, 4 * (i - 1) + 1)
    fword(i) = reinterpret(Float32, word(i))

    nx, ny, nz, mode = Int(word(1)), Int(word(2)), Int(word(3)), Int(word(4))
    (nx > 0 && ny > 0) || throw(CorruptFileError("MRC: nonsensical NX/NY ($nx, $ny)"))
    nz < 1 && (nz = 1)

    T = get(MRC_MODES, mode, nothing)
    T === nothing && throw(
        UnsupportedFormatError(
            mode in (3, 4) ?
            "MRC MODE $mode is complex data, which has no single-channel image form" :
            "MRC MODE $mode is not supported",
        ),
    )

    h = Header()
    for i = 1:56
        name = get(MRC_WORD_NAMES, i, nothing)
        name === nothing && continue
        h[name] = i in MRC_FLOAT_WORDS ? Float64(fword(i)) : Int(word(i))
    end
    h["MAP"] = String(Char.(bytes(src, 4 * 52, 4)))          # word 53, the format stamp
    h["ByteOrder"] = be ? "HighByteFirst" : "LowByteFirst"
    for i = 0:9
        h["LABEL_$(lpad(i, 2, '0'))"] =
            strip(String(Char.(bytes(src, 224 + 80 * i, 80))), ['\0', ' '])
    end

    nsymbt = Int(word(24))
    (nsymbt < 0 || MRC_HEADER_BYTES + nsymbt > n) &&
        throw(CorruptFileError("MRC: NSYMBT of $nsymbt does not fit in the file"))
    dataoffset = MRC_HEADER_BYTES + nsymbt
    framebytes = nx * ny * sizeof(T)

    available = n - dataoffset
    if nz * framebytes > available
        actual = available ÷ framebytes
        actual < 1 && throw(TruncatedFileError("MRC: not even one $(nx)x$(ny) section fits"))
        @warn "MRC: header claims $nz sections but only $actual fit; reading those" file =
            sourcepath(src)
        nz = actual
    end

    byteorder = be ? BigEndian() : LittleEndian()
    specs = FrameSpec[]
    for k = 0:(nz-1)
        fh = copy(h)
        fh["FrameIndex"] = k + 1
        push!(
            specs,
            FrameSpec(
                fh,
                BinaryLayout{T}(
                    dataoffset + k * framebytes,
                    framebytes,
                    (nx, ny);
                    byteorder = byteorder,
                    codec = RawBlob(),
                ),
            ),
        )
    end
    return Header(), specs
end

"""
Decide the byte order.

`MACHST` is the reliable signal where it is set — 0x44 0x44 for little-endian, 0x11 0x11 for
big — but plenty of files leave it zero, so fall back to whichever interpretation gives a
plausible `MODE`.
"""
function _mrc_bigendian(raw::AbstractVector{UInt8})
    m1, m2 = raw[4*53+1], raw[4*53+2]
    (m1 == 0x44 && m2 == 0x44) && return false
    (m1 == 0x11 && m2 == 0x11) && return true
    mode_le = _load_i32(raw, 4 * 3 + 1)
    haskey(MRC_MODES, Int(mode_le)) && return false
    haskey(MRC_MODES, Int(bswap(mode_le))) && return true
    return false
end

"""
    writemrc(path, frames; labels = String[])

Write an MRC stack from a vector of same-sized arrays (or a single array), little-endian, with
a spec-conforming header. Enough to round-trip data and give the tests a fixture.
"""
writemrc(path::AbstractString, A::AbstractArray{<:Any,2}; kwargs...) =
    writemrc(path, [A]; kwargs...)

function writemrc(
    path::AbstractString,
    frames::AbstractVector{<:AbstractArray{T,2}};
    labels::AbstractVector{<:AbstractString} = String[],
) where {T}
    isempty(frames) && throw(ArgumentError("writemrc needs at least one section"))
    mode = findfirst(==(T), MRC_MODES)
    mode === nothing && throw(UnsupportedFormatError("MRC cannot store $T"))
    nx, ny = size(first(frames))
    all(f -> size(f) == (nx, ny), frames) ||
        throw(ArgumentError("all MRC sections must be the same size"))

    words = zeros(Int32, 56)
    words[1] = nx
    words[2] = ny
    words[3] = length(frames)
    words[4] = mode
    words[8], words[9], words[10] = nx, ny, length(frames)
    for (w, v) in ((11, Float32(nx)), (12, Float32(ny)), (13, Float32(length(frames))),
                   (14, 90.0f0), (15, 90.0f0), (16, 90.0f0))
        words[w] = reinterpret(Int32, v)
    end
    words[17], words[18], words[19] = 1, 2, 3
    words[20] = reinterpret(Int32, Float32(minimum(minimum, frames)))
    words[21] = reinterpret(Int32, Float32(maximum(maximum, frames)))
    words[22] = reinterpret(Int32, Float32(sum(sum, frames) / (nx * ny * length(frames))))
    words[56] = min(length(labels), 10)

    Base.open(path, "w") do f
        Base.write(f, reinterpret(UInt8, htol.(words[1:52])))
        Base.write(f, codeunits("MAP "))                       # word 53
        Base.write(f, UInt8[0x44, 0x44, 0x00, 0x00])           # word 54, MACHST little-endian
        Base.write(f, reinterpret(UInt8, htol.(words[55:56])))
        for i = 1:10
            Base.write(f, codeunits(rpad(i <= length(labels) ? labels[i] : "", 80)))
        end
        for A in frames
            Base.write(f, encode(RawBlob(), A))
        end
    end
    return path
end

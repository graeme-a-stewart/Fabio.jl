"""
    Esperanto <: ImageFormat

CrysAlis Pro Esperanto files, as produced by `eiger2crysalis` and read by CrysalisPro.

# On-disk structure

    byte 0            ASCII header: `nlines` × 256 bytes, each CRLF-terminated;
                      the last line ends 0x0D 0x1A. Line 0 states `nlines` and the
                      line width, so neither is assumed.
      line 0          ESPERANTO FORMAT   1 CONSISTING OF   25 LINES OF   256 BYTES EACH
      line 1          IMAGE lnx lny lbx lby "spixelformat"
      …               TIME / PIXELSIZE / WAVELENGTH / GONIOMODEL_1 / STARTANGLESINDEG / …
    byte nlines*256   the pixel data, `Int32`, in one of two encodings:
                        "4BYTE_LONG"   — uncompressed, little-endian
                        "AGI_BITFIELD" — see [`AGIBitfield`](@ref)

The two encodings are two `if` branches in FabIO's reader. Here they differ by one field of a
[`BinaryLayout`](@ref), which is the clearest demonstration of why the format/codec split earns
its keep.

# Header keys

Each line's fields are named by `ESPERANTO_KEYS` and decoded by their name's first
letter — `l`/`i`/`b` integer, `d` float, otherwise a quoted string — the same convention FabIO
uses. Both the raw line and the decoded fields land in the header, so nothing is lost.
"""
struct Esperanto <: ImageFormat end

const ESPERANTO_LINE_WIDTH = 256

"""Field names for each Esperanto header line, in order."""
const ESPERANTO_KEYS = OrderedDict{String,Vector{String}}(
    "IMAGE" => ["lnx", "lny", "lbx", "lby", "spixelformat"],
    "SPECIAL_CCD_1" => [
        "delectronsperadu", "ldarkcorrectionswitch", "lfloodfieldcorrectionswitch/mode",
        "dsystemdcdb2gain", "ddarksignal", "dreadnoiserms",
    ],
    "SPECIAL_CCD_2" => [
        "ioverflowflag", "ioverflowafterremeasureflag", "inumofdarkcurrentimages",
        "inumofmultipleimages", "loverflowthreshold",
    ],
    "SPECIAL_CCD_3" => [
        "ldetector_descriptor", "lisskipcorrelation", "lremeasureturbomode",
        "bfsoftbinningflag", "bflownoisemodeflag",
    ],
    "SPECIAL_CCD_4" => [
        "lremeasureinturbo_done", "lisoverflowthresholdchanged",
        "loverflowthresholdfromimage", "lisdarksignalchanged", "lisreadnoisermschanged",
        "lisdarkdone", "lisremeasurewithskipcorrelation", "lcorrelationshift",
    ],
    "SPECIAL_CCD_5" =>
        ["dblessingrej", "ddarksignalfromimage", "dreadnoisermsfromimage", "dtrueimagegain"],
    "TIME" => ["dexposuretimeinsec", "doverflowtimeinsec", "doverflowfilter"],
    "MONITOR" => ["lmon1", "lmon2", "lmon3", "lmon4"],
    "PIXELSIZE" =>
        ["drealpixelsizex", "drealpixelsizey", "dsithicknessmmforpixeldetector"],
    "TIMESTAMP" => ["timestampstring"],
    "GRIDPATTERN" => ["filename"],
    "STARTANGLESINDEG" => ["dom_s", "dth_s", "dka_s", "dph_s"],
    "ENDANGLESINDEG" => ["dom_e", "dth_e", "dka_e", "dph_e"],
    "GONIOMODEL_1" => [
        "dbeam2indeg", "dbeam3indeg", "detectorrotindeg_x", "detectorrotindeg_y",
        "detectorrotindeg_z", "dxorigininpix", "dyorigininpix", "dalphaindeg",
        "dbetaindeg", "ddistanceinmm",
    ],
    "GONIOMODEL_2" => [
        "dzerocorrectionsoftindeg_om", "dzerocorrectionsoftindeg_th",
        "dzerocorrectionsoftindeg_ka", "dzerocorrectionsoftindeg_ph",
    ],
    "WAVELENGTH" => ["dalpha1", "dalpha2", "dalpha12", "dbeta1"],
    "MONOCHROMATOR" => ["ddvalue-prepolfac", "orientation-type"],
    "ABSTORUN" => ["labstorunscale"],
    "HISTORY" => ["historystring"],
)

function _esperanto_value(name::AbstractString, token::AbstractString)
    c = isempty(name) ? ' ' : name[1]
    if c in ('l', 'i', 'b')
        v = tryparse(Int, token)
        return v === nothing ? token : v
    elseif c == 'd'
        v = tryparse(Float64, token)
        return v === nothing ? token : v
    else
        return strip(token, '"')
    end
end

function _esperanto_header(src::AbstractSource)
    h = Header()
    first = String(Char.(bytes(src, 0, ESPERANTO_LINE_WIDTH)))
    words = split(first)
    (length(words) < 9 || words[1] != "ESPERANTO") &&
        throw(CorruptFileError("not an Esperanto header: $(repr(first[1:min(40, end)]))"))

    nlines = tryparse(Int, words[6])
    width = tryparse(Int, words[9])
    (nlines === nothing || width === nothing) &&
        throw(CorruptFileError("Esperanto: unreadable line count/width in the first line"))
    width == ESPERANTO_LINE_WIDTH ||
        throw(CorruptFileError("Esperanto: unexpected line width $width"))

    h["ESPERANTO FORMAT"] = join(words[3:end], " ")
    h["format"] = something(tryparse(Int, words[3]), words[3])

    for i = 1:(nlines-1)
        raw = bytes(src, i * width, width)
        line = String(Char.(raw))
        tokens = split(line)
        isempty(tokens) && continue
        key = String(tokens[1])
        (length(key) == 1 && codepoint(key[1]) < 32) && continue
        h[key] = join(tokens[2:end], " ")
        names = get(ESPERANTO_KEYS, key, nothing)
        names === nothing && continue
        if key in ("HISTORY", "TIMESTAMP")
            h[names[1]] = strip(join(tokens[2:end], " "), '"')
        else
            for (name, token) in zip(names, tokens[2:end])
                h[name] = _esperanto_value(name, token)
            end
        end
    end
    return h, nlines * width
end

function scan(::Esperanto, src::AbstractSource)
    h, dataoffset = _esperanto_header(src)

    lnx = getheader(h, "lnx", Int)
    lny = getheader(h, "lny", Int)
    (lnx > 0 && lny > 0) ||
        throw(CorruptFileError("Esperanto: nonsensical image size ($lnx, $lny)"))
    dims = (lnx, lny)                      # (fast, slow): a detector row is `lnx` long

    fmt = String(getheader(h, "spixelformat", String, "AGI_BITFIELD"))
    available = filesize(src) - dataoffset
    available > 0 || throw(TruncatedFileError("Esperanto: no pixel data after the header"))

    codec = if fmt == "4BYTE_LONG"
        RawBlob()
    elseif fmt == "AGI_BITFIELD"
        AGIBitfield(_esperanto_rowindex(src, dataoffset, available, lny))
    else
        throw(
            UnsupportedFormatError(
                "Esperanto pixel format $(repr(fmt)); known formats are " *
                "\"4BYTE_LONG\" and \"AGI_BITFIELD\"",
            ),
        )
    end

    layout = BinaryLayout{Int32}(
        dataoffset,
        available,
        dims;
        byteorder = LittleEndian(),
        codec = codec,
    )
    return Header(), FrameSpec[FrameSpec(h, layout)]
end

"""
Read the per-row offset table that closes an AGI bitfield blob.

Layout: a `UInt32` block size, the compressed rows, then `lny` `UInt32` row offsets relative to
the start of the row stream. Returning an empty vector (rather than throwing) when the trailing
table is absent or inconsistent keeps files readable via the sequential path.
"""
function _esperanto_rowindex(
    src::AbstractSource,
    dataoffset::Integer,
    available::Integer,
    nrows::Integer,
)
    available < 4 && return UInt32[]
    datasize = Int(_load_u32(bytes(src, dataoffset, 4), 1))
    tableoffset = dataoffset + 4 + datasize
    tablebytes = 4 * nrows
    (datasize <= 0 || tableoffset + tablebytes > filesize(src)) && return UInt32[]
    raw = bytes(src, tableoffset, tablebytes)
    idx = Vector{UInt32}(undef, nrows)
    @inbounds for i = 1:nrows
        idx[i] = _load_u32(raw, 4 * (i - 1) + 1)
    end
    # A valid table is strictly increasing and stays inside the data block.
    (idx[1] == 0 && all(i -> idx[i] < idx[i+1], 1:(nrows-1)) && Int(idx[end]) < datasize) ||
        return UInt32[]
    return idx
end

# Esperanto stores signed 32-bit integers, and demands a square image whose side is a
# multiple of 4 in [256, 4096]. Enforcing that here means `writeimage` and `convert` cannot
# disagree about it.
function coerce(::Esperanto, A::AbstractArray{T,2}) where {T}
    B = T <: Integer ? A : (@info "Esperanto stores integers; rounding"; round.(A))
    C = convert(Array{Int32}, B)
    n = clamp((maximum(size(C)) + 3) & ~3, 256, 4096)
    size(C) == (n, n) && return C
    @info "Esperanto requires a square image, side a multiple of 4 in [256, 4096]; padding" from =
        size(C) to = (n, n)
    out = zeros(Int32, n, n)
    shift = max((n - size(C, 1)) ÷ 2, 0)
    fast = min(size(C, 1), n - shift)
    slow = min(size(C, 2), n)
    out[(shift+1):(shift+fast), 1:slow] .= @view C[1:fast, 1:slow]
    return out
end

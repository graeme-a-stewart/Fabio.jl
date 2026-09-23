"""
Optional normalised metadata.

FabIO deliberately does not unify header semantics across formats, and neither does this
package by default: [`Header`](@ref) always reports what the file says, spelled as the file
spells it. But six quantities recur across almost every detector format under a different name
and in a different unit, and comparing them by hand is tedious and easy to get wrong. This is a
thin layer over the raw header for exactly those six. The raw header remains the source of
truth, and nothing here is consulted unless asked for.
"""

"""
    ImageMetadata

The handful of quantities that mean the same thing across detector formats, in one unit each.

| field | unit |
|---|---|
| `exposure_time` | seconds |
| `wavelength` | metres |
| `detector_distance` | metres |
| `beam_center` | pixels, `(fast, slow)` |
| `pixel_size` | metres, `(fast, slow)` |
| `timestamp` | `DateTime` |

Every field is `nothing` when the format does not record it, or records it in a way this
layer will not guess at.

**Lengths are metres.** That is not what most of these formats store — Esperanto writes
millimetres, Bruker centimetres, KCD micrometres, and wavelengths are almost universally in
Ångström — so the numbers here will not match the raw header, by design. Metres throughout is
the convention pyFAI uses, which is the library most likely to consume this. Ångström are
`1e10 * m.wavelength`.

`beam_center` is in pixels, which is how Pilatus, MarCCD, Esperanto and Bruker all record it.
d\\*TREK stores it in millimetres instead, and it is converted using that file's pixel size.

Axis order is this package's throughout: `(fast, slow)`, matching `size(frame)`.
"""
struct ImageMetadata
    exposure_time::Union{Nothing,Float64}
    wavelength::Union{Nothing,Float64}
    detector_distance::Union{Nothing,Float64}
    beam_center::Union{Nothing,NTuple{2,Float64}}
    pixel_size::Union{Nothing,NTuple{2,Float64}}
    timestamp::Union{Nothing,DateTime}
end

ImageMetadata(;
    exposure_time = nothing,
    wavelength = nothing,
    detector_distance = nothing,
    beam_center = nothing,
    pixel_size = nothing,
    timestamp = nothing,
) = ImageMetadata(
    exposure_time,
    wavelength,
    detector_distance,
    beam_center,
    pixel_size,
    timestamp,
)

function Base.show(io::IO, ::MIME"text/plain", m::ImageMetadata)
    println(io, "ImageMetadata:")
    _showfield(io, "exposure_time", m.exposure_time, "s")
    _showfield(io, "wavelength", m.wavelength, "m")
    _showfield(io, "detector_distance", m.detector_distance, "m")
    _showfield(io, "beam_center", m.beam_center, "px")
    _showfield(io, "pixel_size", m.pixel_size, "m")
    _showfield(io, "timestamp", m.timestamp, "")
end

function _showfield(io::IO, name, value, unit)
    print(io, "  ", rpad(name, 18), " ")
    if value === nothing
        println(io, "—")
    else
        println(io, value, isempty(unit) ? "" : " " * unit)
    end
end

# ------------------------------------------------------------------ unit conversions

const ANGSTROM = 1e-10
const MILLIMETRE = 1e-3
const CENTIMETRE = 1e-2
const MICROMETRE = 1e-6

"""The first number in a whitespace- or comma-separated string, or `nothing`."""
function _firstnumber(v)
    v === nothing && return nothing
    v isa Number && return Float64(v)
    m = match(r"[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?", String(v))
    m === nothing && return nothing
    return tryparse(Float64, m.match)
end

"""The `n`-th number in a string of them, or `nothing`."""
function _nthnumber(v, n::Int)
    v === nothing && return nothing
    nums = collect(eachmatch(r"[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?", String(v)))
    length(nums) < n && return nothing
    return tryparse(Float64, nums[n].match)
end

"""`x * scale`, propagating `nothing`."""
_scaled(x, scale) = x === nothing ? nothing : x * scale

_pair(a, b) = (a === nothing || b === nothing) ? nothing : (Float64(a), Float64(b))

# ---------------------------------------------------------------------- the entry point

"""
    normalise(frame) -> ImageMetadata
    normalise(fmt, header) -> ImageMetadata

The common metadata of a frame, in the units [`ImageMetadata`](@ref) documents.

```julia
m = Fabio.normalise(Fabio.readimage("scan.esperanto"))
m.exposure_time            # 1.0
1e10 * m.wavelength        # 0.29, back in Ångström
```

A format with no method here yields an all-`nothing` result rather than an error: absence of
normalised metadata is an ordinary outcome, not a failure. Adding support for a format is one
method, and works as well from another package as from inside this one.
"""
normalise(f::ImageFrame) = normalise(imageformat(f), header(f))
normalise(::Nothing, ::Header) = ImageMetadata()
normalise(::ImageFormat, ::Header) = ImageMetadata()

# ------------------------------------------------------------------------- per format

"""
Esperanto decodes its own header fields into numbers, so this is only unit conversion.

`DESIGN.md` §11 names this format as the demonstration, and it is: all six quantities are
present, and all six are read here.
"""
function normalise(::Esperanto, h::Header)
    return ImageMetadata(
        exposure_time = _firstnumber(getci(h, "dexposuretimeinsec")),
        wavelength = _scaled(_firstnumber(getci(h, "dalpha1")), ANGSTROM),
        detector_distance = _scaled(_firstnumber(getci(h, "ddistanceinmm")), MILLIMETRE),
        beam_center = _pair(
            _firstnumber(getci(h, "dxorigininpix")),
            _firstnumber(getci(h, "dyorigininpix")),
        ),
        pixel_size = _pair(
            _scaled(_firstnumber(getci(h, "drealpixelsizex")), MILLIMETRE),
            _scaled(_firstnumber(getci(h, "drealpixelsizey")), MILLIMETRE),
        ),
    )
end

"""
MarCCD's binary header stores scaled integers, which the reader has already divided out into
millimetres, pixels, seconds and Ångström. See `MARCCD_FIELDS`.
"""
function normalise(::TIFFLike{:marccd}, h::Header)
    return ImageMetadata(
        exposure_time = _firstnumber(getci(h, "exposure_time")),
        wavelength = _scaled(_firstnumber(getci(h, "source_wavelength")), ANGSTROM),
        detector_distance = _scaled(_firstnumber(getci(h, "xtal_to_detector")), MILLIMETRE),
        beam_center = _pair(_firstnumber(getci(h, "beam_x")), _firstnumber(getci(h, "beam_y"))),
        pixel_size = _pair(
            _scaled(_firstnumber(getci(h, "pixelsize_x")), MILLIMETRE),
            _scaled(_firstnumber(getci(h, "pixelsize_y")), MILLIMETRE),
        ),
    )
end

"""
Pilatus writes `# key value unit` lines into the TIFF `ImageDescription`, and the same block
appears in the CBF files its detectors write, so one implementation serves both.

Unusually among these formats, Dectris already records SI: `Pixel_size 172e-6 m` and
`Detector_distance 0.15 m` need no conversion. The wavelength is in Ångström.
"""
function _normalise_pilatus(h::Header)
    beam = getci(h, "Beam_xy")
    return ImageMetadata(
        exposure_time = _firstnumber(getci(h, "Exposure_time")),
        wavelength = _scaled(_firstnumber(getci(h, "Wavelength")), ANGSTROM),
        detector_distance = _firstnumber(getci(h, "Detector_distance")),
        beam_center = _pair(_nthnumber(beam, 1), _nthnumber(beam, 2)),
        # "172e-6 m x 172e-6 m" — the two numbers are the two axes.
        pixel_size = _pair(
            _nthnumber(getci(h, "Pixel_size"), 1),
            _nthnumber(getci(h, "Pixel_size"), 2),
        ),
    )
end

normalise(::TIFFLike{:pilatus}, h::Header) = _normalise_pilatus(h)
normalise(::CBF, h::Header) = _normalise_pilatus(h)

"""
d\\*TREK and ADSC write plain `KEY=value;` text in millimetres and Ångström.

The beam centre is the exception among the formats here: it is recorded in millimetres rather
than pixels, so it is divided by this file's pixel size to reach the common convention.
"""
function normalise(::Dtrek, h::Header)
    px = _firstnumber(getci(h, "PIXEL_SIZE"))
    bx = _firstnumber(getci(h, "BEAM_CENTER_X"))
    by = _firstnumber(getci(h, "BEAM_CENTER_Y"))
    beam = (px === nothing || px == 0) ? nothing : _pair(
        bx === nothing ? nothing : bx / px,
        by === nothing ? nothing : by / px,
    )
    return ImageMetadata(
        exposure_time = _firstnumber(getci(h, "TIME")),
        wavelength = _scaled(_firstnumber(getci(h, "WAVELENGTH")), ANGSTROM),
        detector_distance = _scaled(_firstnumber(getci(h, "DISTANCE")), MILLIMETRE),
        beam_center = beam,
        pixel_size = _pair(_scaled(px, MILLIMETRE), _scaled(px, MILLIMETRE)),
        timestamp = _parsedate(getci(h, "DATE")),
    )
end

"""
Bruker packs several values into each fixed-width field; the first is the one wanted.

`DISTANC` is in centimetres and `WAVELEN` begins with the average wavelength, both by the
format's documented convention rather than anything the files to hand could confirm. `CENTER`
is in pixels, which the files do confirm: 382 of 768 columns and 508 of 1024 rows.

Pixel size is deliberately absent. It is derivable from the pixels-per-centimetre figure inside
`DETTYPE`, but that field's layout varies by detector and guessing at it would put a wrong
number where `nothing` is honest.
"""
function normalise(::Bruker, h::Header)
    return ImageMetadata(
        exposure_time = _firstnumber(getci(h, "CUMULAT")),
        wavelength = _scaled(_firstnumber(getci(h, "WAVELEN")), ANGSTROM),
        detector_distance = _scaled(_firstnumber(getci(h, "DISTANC")), CENTIMETRE),
        beam_center = _pair(
            _nthnumber(getci(h, "CENTER"), 1),
            _nthnumber(getci(h, "CENTER"), 2),
        ),
        timestamp = _parsedate(getci(h, "CREATED")),
    )
end

"""KappaCCD records exposure in seconds, pixel size in micrometres and Alpha1 in Ångström."""
function normalise(::KCD, h::Header)
    return ImageMetadata(
        exposure_time = _firstnumber(getci(h, "Exposure time")),
        wavelength = _scaled(_firstnumber(getci(h, "Alpha1")), ANGSTROM),
        pixel_size = _pair(
            _scaled(_firstnumber(getci(h, "pixel X-size (um)")), MICROMETRE),
            _scaled(_firstnumber(getci(h, "pixel Y-size (um)")), MICROMETRE),
        ),
    )
end

"""WinSpec records an exposure in seconds and a wavelength in nanometres at the grating."""
normalise(::SPE, h::Header) =
    ImageMetadata(exposure_time = _firstnumber(getci(h, "exposure_time")))

# ------------------------------------------------------------------------------ NeXus

"""
Metres per unit, for the length units NeXus files write. Looked up lower-cased, since writers
disagree about capitals and nothing here is ambiguous once they are gone.
"""
const _NX_LENGTH = Dict(
    (u => 1.0 for u in ("m", "metre", "metres", "meter", "meters"))...,
    (u => 1e-2 for u in ("cm", "centimetre", "centimetres", "centimeter", "centimeters"))...,
    (u => 1e-3 for u in ("mm", "millimetre", "millimetres", "millimeter", "millimeters"))...,
    (u => 1e-6 for u in ("um", "µm", "μm", "micron", "microns", "micrometre", "micrometres",
        "micrometer", "micrometers"))...,
    (u => 1e-9 for u in ("nm", "nanometre", "nanometres", "nanometer", "nanometers"))...,
    (u => 1e-10 for u in ("a", "å", "Å", "ang", "angstrom", "angstroms", "ångström"))...,
    (u => 1e-12 for u in ("pm", "picometre", "picometres", "picometer", "picometers"))...,
)

"""Electronvolts per unit. Case matters here and only here: `meV` and `MeV` differ by 10⁹."""
const _NX_ENERGY = Dict(
    "eV" => 1.0, "ev" => 1.0, "keV" => 1e3, "KeV" => 1e3, "kev" => 1e3,
    "meV" => 1e-3, "MeV" => 1e6, "GeV" => 1e9,
)

"""Seconds per unit."""
const _NX_TIME = Dict(
    (u => 1.0 for u in ("s", "sec", "secs", "second", "seconds"))...,
    (u => 1e-3 for u in ("ms", "millisecond", "milliseconds"))...,
    (u => 1e-6 for u in ("us", "µs", "μs", "microsecond", "microseconds"))...,
    (u => 1e-9 for u in ("ns", "nanosecond", "nanoseconds"))...,
)

const _NX_PIXELS = Set(("pixel", "pixels", "px"))

"""`h c` in eV·m, to turn a photon energy into a wavelength."""
const _HC_EV_M = 1.239841984332e-6

"""A header value as a single number, or `nothing` — a string holding one number counts."""
_nxnumber(v) = v isa Real ? Float64(v) : v isa AbstractString ? _firstnumber(v) : nothing

"""The `units` attribute of `path` as the file spells it, stripped, or `nothing`."""
function _nxunits(h::Header, path)
    u = get(h, path * "@units", nothing)
    u isa AbstractString || return nothing
    u = strip(u)
    return isempty(u) ? nothing : String(u)
end

"""
`path`'s value in SI via `table`, or `nothing` when either the value or a unit the table knows
is missing. A field with no `units` attribute is not assumed to be in any particular unit:
real files omit it on fields where the conventional unit differs between facilities.
"""
function _nxquantity(h::Header, path, table::Dict; lowercase_units = true)
    x = _nxnumber(get(h, path, nothing))
    x === nothing && return nothing
    u = _nxunits(h, path)
    u === nothing && return nothing
    scale = get(table, lowercase_units ? lowercase(u) : u, nothing)
    scale === nothing && return nothing
    return x * scale
end

"""The groups of NeXus class `class`, in file order, from the `@NX_class` keys of the header."""
function _nxgroups(h::Header, class::AbstractString)
    out = String[]
    for (k, v) in h
        endswith(k, "@NX_class") && v == class && push!(out, k[1:end-length("@NX_class")])
    end
    return out
end

"""The first of `fields` found in any group of `class`, through `f(path)`, that is not `nothing`."""
function _nxfirst(f, h::Header, class, fields)
    for field in fields, g in _nxgroups(h, class)
        haskey(h, g * "/" * field) || continue
        v = f(g * "/" * field)
        v === nothing || return v
    end
    return nothing
end

"""
NeXus names its fields and their units explicitly, so this is mostly finding the right group.

- **Detector** fields come from the NXdetector the image belongs to (`HDF5Detector`, which the
  HDF5 reader records only when it can tell). `count_time` is the exposure; it may differ per
  frame, and each frame's header holds its own.
- **Wavelength** is the NXbeam `incident_wavelength`, then the NXmonochromator `wavelength`,
  then either's photon energy converted.
- **Beam centre** is converted to pixels. NeXus records it as a length, which is divided by
  the pixel size; a `pixel` unit is taken as it stands.
- **Axes.** `x` is taken as the fast axis and `y` the slow, as Dectris and DIALS write and read
  them.
- **Timestamp** is the NXentry `start_time`, an ISO 8601 string. The wall-clock time is kept and
  any UTC offset dropped, as for every other format here, whose headers carry no zone at all.

A field without a `units` attribute gives `nothing`: the files to hand include a beam centre
that is millimetres in one and evidently pixels in another, neither saying so. Detector
geometry recorded only as an NXtransformations chain — as modern NXmx files do — is not
evaluated; its raw values are in the header.
"""
function normalise(::NexusLike, h::Header)
    det = get(h, "HDF5Detector", nothing)
    field(name) = det === nothing ? "" : det * "/" * name
    length_of(p) = _nxquantity(h, p, _NX_LENGTH)
    energy_to_wavelength(p) = begin
        e = _nxquantity(h, p, _NX_ENERGY; lowercase_units = false)
        e === nothing || e <= 0 ? nothing : _HC_EV_M / e
    end

    wavelength = something(
        _nxfirst(length_of, h, "NXbeam", ("incident_wavelength",)),
        _nxfirst(length_of, h, "NXmonochromator", ("wavelength",)),
        _nxfirst(energy_to_wavelength, h, "NXbeam", ("incident_energy",)),
        _nxfirst(energy_to_wavelength, h, "NXmonochromator", ("energy",)),
        Some(nothing),
    )

    px = length_of(field("x_pixel_size"))
    py = length_of(field("y_pixel_size"))
    beam_center = _pair(_nxbeamcenter(h, field("beam_center_x"), px),
                        _nxbeamcenter(h, field("beam_center_y"), py))

    entry = _nxgroups(h, "NXentry")
    start = isempty(entry) ? nothing : get(h, entry[1] * "/start_time", nothing)

    return ImageMetadata(
        exposure_time = _nxquantity(h, field("count_time"), _NX_TIME),
        wavelength = wavelength,
        detector_distance = length_of(field("distance")),
        beam_center = beam_center,
        pixel_size = _pair(px, py),
        timestamp = _nxdate(start),
    )
end

"""One beam-centre coordinate in pixels, from a length and that axis's pixel size."""
function _nxbeamcenter(h::Header, path, pixelsize)
    x = _nxnumber(get(h, path, nothing))
    x === nothing && return nothing
    u = _nxunits(h, path)
    u === nothing && return nothing
    lowercase(u) in _NX_PIXELS && return x
    scale = get(_NX_LENGTH, lowercase(u), nothing)
    (scale === nothing || pixelsize === nothing || pixelsize == 0) && return nothing
    return x * scale / pixelsize
end

"""An ISO 8601 NeXus time, to millisecond precision and without its UTC offset."""
function _nxdate(v)
    v isa AbstractString || return nothing
    m = match(r"^\s*(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?", v)
    m === nothing && return nothing
    frac = m[3] === nothing ? "" : rpad(m[3][1:min(end, 4)], 4, '0')
    return tryparse(DateTime, m[1] * "T" * m[2] * frac,
        isempty(frac) ? dateformat"y-m-dTH:M:S" : dateformat"y-m-dTH:M:S.s")
end

# -------------------------------------------------------------------------- timestamps

"""
Parse the date formats these headers use, or give up quietly.

Three shapes occur among the formats read here: C `asctime` as d\\*TREK writes it, Bruker's
`dd-Mon-yyyy` with the time in a second field, and an ISO-like form. A header date that does
not parse is worth no exception — the raw string is still in the header.
"""
function _parsedate(v)
    v === nothing && return nothing
    s = strip(replace(String(v), r"\s+" => " "))
    isempty(s) && return nothing
    for fmt in (
        dateformat"e u d H:M:S y",        # Wed Nov 11 11:24:13 2009
        dateformat"d-u-y H:M:S",          # 07-Mar-2024 21:49:06
        dateformat"y-m-d H:M:S",
        dateformat"y-m-dTH:M:S",
        dateformat"d/m/y H:M:S",
    )
        t = tryparse(DateTime, s, fmt)
        t === nothing || return t
    end
    return nothing
end

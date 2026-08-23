"""
    writeformat(fmt, path, arrays, headers; kwargs...)

**The writer extension point**, and the counterpart to [`scan`](@ref).

`arrays` and `headers` are parallel vectors, already put through [`coerce`](@ref), so a format
implementing this method receives data it can physically store. Single-frame formats should
reject a request to write more than one frame rather than silently dropping frames; the helper
[`writeone`](@ref) does that in one line.

Formats implement this by delegating to their own `write*` function, which is where the actual
byte layout lives. Keeping the two apart means the generic path — resolving the format,
coercing the array, checking the frame count — is written once, while each format's writer
keeps whatever bespoke keyword arguments its file format calls for.

Default: throw, naming the formats that *can* write.
"""
function writeformat(
    fmt::ImageFormat,
    path::AbstractString,
    ::AbstractVector,
    ::AbstractVector;
    kwargs...,
)
    throw(
        UnsupportedFormatError(
            "$(nameof(typeof(fmt))) has no writer; formats that can be written are " *
            join(string.(writableformats()), ", "),
        ),
    )
end

"""
    writeone(f, fmt, path, arrays, headers)

Apply a single-frame writer `f(path, array, header)` to what is meant to be one frame,
throwing if more than one was supplied.
"""
function writeone(f, fmt::ImageFormat, path::AbstractString, arrays, headers; kwargs...)
    length(arrays) == 1 || throw(
        ArgumentError(
            "$(nameof(typeof(fmt))) writes one frame per file, got $(length(arrays))",
        ),
    )
    return f(path, arrays[1], headers[1]; kwargs...)
end

"""
    canwrite(fmt) -> Bool

Whether `fmt` implements [`writeformat`](@ref).

Derived rather than declared, so it cannot drift from the truth the way a hand-kept flag
does — the same reason [`formats`](@ref) is generated from the registry instead of being
maintained in prose.
"""
function canwrite(fmt::ImageFormat)
    m = which(writeformat, Tuple{typeof(fmt),String,Vector,Vector})
    # `hasmethod` would be no help: the fallback above accepts every `ImageFormat`, so it
    # matches for all of them. What distinguishes a format that can really write is that the
    # method resolved for it is more specific than that fallback.
    return m.sig.parameters[2] !== ImageFormat
end

"""
    writableformats() -> Vector{Symbol}

The registry names that can be written.
"""
writableformats() = [e.name for e in REGISTRY if canwrite(e.format)]

"""
Resolve the format to write from a filename extension.

Only formats that can actually write are considered, which is what keeps `out.tif` from
resolving to the Pilatus reader — it shares the extension with plain TIFF but has no writer.
Several formats legitimately share an extension (`.img` is d\\*TREK, R-AXIS and OXD), and there
is nothing in a name to separate them, so the highest-priority writable match wins and the
error suggests naming the format outright.
"""
function writeformatforpath(path::AbstractString)
    stem, _ = stripcompression(String(path))
    ext = lowercase(strip(last(splitext(stem)), '.'))
    isempty(ext) && throw(
        ArgumentError(
            "cannot tell the format from \"$path\": it has no extension. " *
            "Pass `format = ...` (writable: " *
            join(string.(writableformats()), ", ") * ")",
        ),
    )
    for e in REGISTRY
        if ext in e.extensions && canwrite(e.format)
            return e.format
        end
    end
    throw(
        UnsupportedFormatError(
            "no writer is registered for the extension \".$ext\". " *
            "Pass `format = ...` (writable: " *
            join(string.(writableformats()), ", ") * ")",
        ),
    )
end

"""
    writeimage(path, frame; format=nothing, kwargs...)
    writeimage(path, array; format=nothing, header=Header(), kwargs...)
    writeimage(path, frames::AbstractVector; format=nothing, kwargs...)

Write one frame, one bare array, or a stack of either.

The format comes from `path`'s extension unless `format` names one. Any remaining keyword
arguments are passed through to the format's own writer, which is where per-format options
such as `ascii` for Netpbm or `bigendian` for Fit2D live.

`array` may be any `AbstractMatrix`, including an [`ImageFrame`](@ref); passing a frame keeps
its header, passing a bare array writes the `header` keyword (empty by default).

```julia
frame = Fabio.readimage("in.cbf")
Fabio.writeimage("out.edf", frame)                       # format from the extension
Fabio.writeimage("out.edf", frame; format = Fabio.EDF()) # or say it outright
Fabio.writeimage("stack.mrc", [f1, f2, f3])              # multi-frame, where the format allows
```

Every write goes through [`coerce`](@ref) first, so a format that cannot store what it was
handed adapts the data rather than writing an invalid file — a Fit2D mask reduces each pixel
to a bit, and Esperanto pads to a square whose side is a multiple of four, both saying so.

Note the axis convention: `array` is `(fast, slow)` like everything else here, so a frame read
by this package is written back the way it came without a permutation.
"""
function writeimage(
    path::AbstractString,
    frames::AbstractVector;
    format::Union{Nothing,ImageFormat} = nothing,
    kwargs...,
)
    stem, sfx = stripcompression(String(path))
    isempty(sfx) && return _writeplain(String(path), frames, format; kwargs...)
    # Reading decompresses transparently, so writing compresses transparently, or the two are
    # not inverses: without this, `out.edf.gz` would receive a plain EDF under a name that
    # says otherwise, and reading it straight back would fail on the missing gzip header.
    sfx == ".gz" || throw(
        UnsupportedFormatError(
            "writing $sfx output is not supported; only .gz is, matching what the reader " *
            "can decompress without an optional package",
        ),
    )
    tmp = tempname() * last(splitext(stem))
    try
        _writeplain(tmp, frames, format === nothing ? writeformatforpath(stem) : format;
                    kwargs...)
        Base.open(path, "w") do io
            Base.write(io, transcode(GzipCompressor, Base.read(tmp)))
        end
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
    return String(path)
end

function _writeplain(
    path::AbstractString,
    frames::AbstractVector,
    format::Union{Nothing,ImageFormat};
    kwargs...,
)
    isempty(frames) && throw(ArgumentError("no frames to write"))
    fmt = format === nothing ? writeformatforpath(path) : format
    canwrite(fmt) || throw(
        UnsupportedFormatError(
            "$(nameof(typeof(fmt))) has no writer; formats that can be written are " *
            join(string.(writableformats()), ", "),
        ),
    )
    arrays = [coerce(fmt, _writedata(f)) for f in frames]
    headers = Header[_writeheader(f) for f in frames]
    writeformat(fmt, String(path), arrays, headers; kwargs...)
    return String(path)
end

writeimage(path::AbstractString, frame::ImageFrame; kwargs...) =
    writeimage(path, [frame]; kwargs...)

function writeimage(
    path::AbstractString,
    A::AbstractMatrix;
    header::Header = Header(),
    kwargs...,
)
    return writeimage(path, [ImageFrame(A, header)]; kwargs...)
end

_writedata(f::ImageFrame) = data(f)
_writedata(A::AbstractArray) = A
_writeheader(f::ImageFrame) = header(f)
_writeheader(::AbstractArray) = Header()

# ------------------------------------------------------------------ header translation

"""
    layoutkeys(fmt) -> NTuple{N,String}

The header keys that describe how *this* format stores its pixels, rather than anything about
the experiment: shape, element type, byte order, offsets, and the format's own stamps.

They serve two purposes, and both are about keys that are true of one file and false of the
next. A writer must not let a caller's stale copy of them through, or the file ends up saying
its dimensions twice and disagreeing; and [`convertimage`](@ref) drops the *source* format's
set, because carrying `Dim_1` into a CBF describes nothing there.

The distinction is the one the FabIO documentation itself draws — "information in the header
about the binary part of the image (compression, endianness, shape) are interpreted however,
other metadata are exposed as they are recorded in the file". This names the first kind.

Default: none, which carries every key exactly as FabIO does.
"""
layoutkeys(::ImageFormat) = ()

"""
    striplayoutkeys(fmt, header) -> Header

`header` without the keys `fmt` generates for itself. Case-insensitive, since writers within a
single format disagree about capitalisation.
"""
function striplayoutkeys(fmt::ImageFormat, h::Header)
    keep = layoutkeys(fmt)
    isempty(keep) && return h
    drop = Set(uppercase(k) for k in keep)
    out = Header()
    for (k, v) in h
        uppercase(k) in drop || (out[k] = v)
    end
    return out
end

"""
    convertimage(frame, fmt) -> ImageFrame

Adapt `frame` to what `fmt` can store, in both its pixels and its metadata.

This is [`coerce`](@ref) — element type, and shape where the format insists — together with
the header translation `coerce` cannot do, since only the frame knows where it came from. The
result is an ordinary [`ImageFrame`](@ref) tagged with the destination format, ready for
[`writeimage`](@ref):

```julia
Fabio.writeimage("my.edf", Fabio.convertimage(Fabio.readimage("my.tiff"), Fabio.EDF()))
```

Going through `convertimage` is not required — `writeimage` coerces anyway — but it is what
removes the source format's [`layoutkeys`](@ref), so a converted file does not carry a
description of the file it came from.

FabIO's equivalent, `image.convert("edf")`, passes the header through untouched: its
`converters.CONVERSION_HEADER` holds exactly one entry, EDF to EDF, and that one is the
identity. Its data table is seven `astype(int)` casts, which `coerce` subsumes and improves on
by being per-format and saying when it loses something.
"""
function convertimage(frame::ImageFrame, fmt::ImageFormat)
    h = header(frame)
    from = imageformat(frame)
    from === nothing || (h = striplayoutkeys(from, h))
    return ImageFrame(
        coerce(fmt, data(frame)),
        h;
        fileindex = frame.fileindex,
        seriesindex = frame.seriesindex,
        source = frame.source,
        format = fmt,
    )
end

# ------------------------------------------------------------------- storage contract

"""
    storagetypes(fmt) -> Tuple{Vararg{DataType}}

The element types that survive a write and read back **unchanged** through `fmt`.

This is the writer's half of the contract [`coerce`](@ref) enforces. Anything in this tuple is
stored as it stands; anything else is either converted to one of these by `coerce`, saying so
when the conversion loses information, or refused with an [`UnsupportedFormatError`](@ref)
naming the format. What must never happen is the third thing — a bare `MethodError` from some
per-format writer two calls down, or worse, a value silently reinterpreted as another type.

Derived from each reader's own type table wherever the reader hands back what the file stores,
so the two cannot drift. A few formats transform on read — KCD sums its readouts into `Int32`,
MPA is `Float64` by construction — and those say so explicitly below.

Empty for a format with no writer.
"""
storagetypes(::ImageFormat) = ()

"""
    narrowstorage(fmt, A) -> Array

Convert `A` to the narrowest of `fmt`'s [`storagetypes`](@ref) that holds its values.

This is the body of most `coerce` methods. A float array is rounded first; a value that fits
nowhere is clamped to the widest type's range rather than wrapped, because wrapping turns a
minimum into a maximum, which is the worst possible way for image data to be wrong. Both steps
say so when they happen.

Choosing by the data rather than by the input type is what the formats themselves do: Bruker
records a `NPIXELB` byte width, GE a bit depth, Netpbm a `MAXVAL`. Writing `Int32[1 2; 3 4]` as
one byte per pixel is not a loss, it is the format being used properly.
"""
function narrowstorage(fmt::ImageFormat, A::AbstractArray{T,2}) where {T}
    stored = storagetypes(fmt)
    isempty(stored) && throw(
        UnsupportedFormatError("$(nameof(typeof(fmt))) declares no storage types"),
    )
    T in stored && return A

    ints = filter(S -> S <: Integer, collect(stored))
    if T <: AbstractFloat && !isempty(filter(S -> S <: AbstractFloat, stored))
        # A float format taking a float: widen or narrow, never round.
        F = first(sort!(filter(S -> S <: AbstractFloat, collect(stored)); by = sizeof))
        return convert(Array{F}, A)
    end
    isempty(ints) && return convert(Array{first(stored)}, A)

    B = A
    if T <: AbstractFloat
        @info "$(nameof(typeof(fmt))) stores integers; rounding" from = T
        B = round.(A)
    end
    lo, hi = isempty(B) ? (0.0, 0.0) : (Float64(minimum(B)), Float64(maximum(B)))
    sort!(ints; by = sizeof)
    S = something(
        findfirst(x -> Float64(typemin(x)) <= lo && hi <= Float64(typemax(x)), ints),
        0,
    )
    target = S == 0 ? last(ints) : ints[S]
    if S == 0
        @warn "$(nameof(typeof(fmt))) cannot hold these values; clamping" range = (lo, hi) to =
            target
    end
    return [_clampto(target, x) for x in B]
end

"""Convert one value to `S`, clamping rather than wrapping."""
@inline function _clampto(::Type{S}, x) where {S<:Integer}
    x < 0 && return zero(S) <= typemin(S) ? S(typemin(S)) : zero(S)
    return x > typemax(S) ? typemax(S) : S(x)
end

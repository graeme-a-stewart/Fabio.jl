"""
Filename arithmetic, and series that span several files.

FabIO offers two overlapping ways to walk a set of images: `next()` on an image, whose meaning
depends on the format — the next *frame* for a multi-frame format, the next *file* for a
single-frame one — and an explicit file series. Its own documentation is candid that "for
formats which are possibly multi-framed like EDF and TIFF, the behaviour can be complicated".

This package keeps the two apart, as `DESIGN.md` §4.2 sets out. Frames within a file are
reached with `file[i]`; frames across files are reached with a [`FileSeries`](@ref), indexed
exactly the same way; and filename arithmetic, when that is genuinely what is wanted, is a
separate utility that does nothing but manipulate strings.
"""

# ------------------------------------------------------------------ filename arithmetic

"""Whether `ext` (with its dot) is an extension some registered format claims."""
function _isformatextension(ext::AbstractString)
    isempty(ext) && return false
    e = lowercase(strip(ext, [Char(46)]))
    isempty(e) && return false
    for entry in REGISTRY
        e in entry.extensions && return true
    end
    return false
end

"""
    splitfilenumber(path) -> (prefix, number, digits, suffix)

Break a filename into the number it carries and the text either side, such that

    prefix * lpad(number, digits, '0') * suffix == path

`number` is `nothing` when the name holds no digits, and `digits` records the zero padding so
it can be reproduced.

The number is the **last run of digits** left once any compression suffix and any trailing
components naming a registered format have been peeled off. That last step is what it takes to
read `200mMmgso4_001.mar2300` correctly: the final digits in the name belong to the detector,
not to the sequence, and only knowing that `.mar2300` is a format extension separates them.
FabIO consults its codec registry for the same reason. A name whose extension is *itself* the
number — Bruker's `scan.0001` — is recognised before any of this.
"""
function splitfilenumber(path::AbstractString)
    p = String(path)
    dir, name = splitdir(p)
    base, csfx = stripcompression(name)
    stem, ext = splitext(base)

    # Bruker's `name.0001`: the extension is the frame number.
    if length(ext) > 1 && all(isdigit, ext[2:end])
        return (joinpath(dir, stem * "."), parse(Int, ext[2:end]), length(ext) - 1, csfx)
    end

    # Peel off every trailing component that names a registered format, so that the digits in
    # `200mMmgso4_001.mar2300` are found in the sequence number and not in the detector name.
    # This is the one place the arithmetic has to know what a format extension looks like;
    # FabIO consults the same registry for the same reason.
    tail = ext
    while _isformatextension(ext)
        stem, ext = splitext(stem)
        tail = ext * tail
        isempty(ext) && break
    end
    ext = tail

    m = nothing
    for candidate in eachmatch(r"[0-9]+", stem)
        m = candidate
    end
    m === nothing && return (p, nothing, 0, "")

    lo = m.offset
    hi = m.offset + ncodeunits(m.match) - 1
    return (
        joinpath(dir, stem[1:prevind(stem, lo)]),
        parse(Int, m.match),
        length(m.match),
        stem[nextind(stem, hi):end] * ext * csfx,
    )
end

"""Render `n` in `digits` columns, zero padded, with a leading sign inside the width."""
function _padnumber(n::Integer, digits::Integer)
    n >= 0 && return lpad(string(n), digits, '0')
    return "-" * lpad(string(-n), max(digits - 1, 1), '0')
end

"""
    filenumber(path) -> Union{Nothing,Int}

The number embedded in a filename, or `nothing`. FabIO calls this `extract_filenumber`.
"""
filenumber(path::AbstractString) = splitfilenumber(path)[2]

"""
    jumpfile(path, n) -> String

`path` with its embedded number replaced by `n`, keeping the zero padding.

```julia
Fabio.jumpfile("200mMmgso4_001.mar2300", 12)   # "200mMmgso4_012.mar2300"
```
"""
function jumpfile(path::AbstractString, n::Integer)
    prefix, num, digits, suffix = splitfilenumber(path)
    num === nothing && throw(
        ArgumentError("no number to change in \"$path\"; filename arithmetic needs one"),
    )
    return prefix * _padnumber(n, digits) * suffix
end

"""
    nextfile(path) -> String

The next filename in a numbered series. See [`jumpfile`](@ref).
"""
function nextfile(path::AbstractString)
    num = filenumber(path)
    num === nothing && throw(
        ArgumentError("no number to increment in \"$path\"; filename arithmetic needs one"),
    )
    return jumpfile(path, num + 1)
end

"""
    prevfile(path) -> String

The previous filename in a numbered series.

Counting below zero throws rather than producing a name with a negative number in it. FabIO
returns `img_-001.edf` for the file before `img_0000.edf`, which cannot exist and defers the
error to whatever tries to open it.
"""
function prevfile(path::AbstractString)
    num = filenumber(path)
    num === nothing && throw(
        ArgumentError("no number to decrement in \"$path\"; filename arithmetic needs one"),
    )
    num <= 0 && throw(ArgumentError("\"$path\" is number $num; there is nothing before it"))
    return jumpfile(path, num - 1)
end

"""
    seriespaths(first; last=nothing, count=nothing, step=1) -> Vector{String}

The filenames of a series beginning at `first`.

With neither `last` nor `count`, the series runs until a name does not exist on disk, which is
what "the files of this scan" usually means. `last` stops at a given filename (inclusive) and
`count` after a given number of files; both accept names that are not yet written.
"""
function seriespaths(
    firstpath::AbstractString;
    last::Union{Nothing,AbstractString} = nothing,
    count::Union{Nothing,Integer} = nothing,
    step::Integer = 1,
)
    step == 0 && throw(ArgumentError("step must not be zero"))
    num = filenumber(firstpath)
    (num === nothing && (last !== nothing || count !== nothing || step != 1)) && throw(
        ArgumentError("\"$firstpath\" carries no number, so a series cannot be built from it"),
    )
    num === nothing && return [String(firstpath)]

    stopnum = last === nothing ? nothing : filenumber(last)
    out = String[]
    n = num
    while true
        p = jumpfile(firstpath, n)
        count !== nothing && length(out) >= count && break
        if stopnum === nothing && count === nothing
            isfile(p) || break
        end
        push!(out, p)
        stopnum !== nothing && n == stopnum && break
        n += step
        stopnum !== nothing && ((step > 0 && n > stopnum) || (step < 0 && n < stopnum)) && break
    end
    return out
end

# ------------------------------------------------------------------------------ series

"""
    FileSeries <: AbstractVector{ImageFrame}

Several image files read as one sequence of frames.

`series[i]` is the `i`-th frame **of the whole series**, counting across file boundaries, and
`length(series)` is the total number of frames. That is the unambiguous reading FabIO's own
`next()` cannot offer, and it means the documented multi-file example reads the same whether
the format stores one frame per file or many.

Files are opened one at a time and the most recent stays open, so walking a series in order
opens each file exactly once. Random access across a large series reopens as it goes, which is
the cost the FabIO documentation is describing when it notes that sequential access is about
twice as fast.

A frame stays readable after the series has moved on to another file, or been closed: a
memory-mapped frame keeps its mapping alive through the array itself, independently of the
file handle it came from, so nothing is copied and nothing dangles.

Not thread-safe: it holds an open file and rebinds it as the index moves. Open one series per
task, or read frames out into arrays first.
"""
mutable struct FileSeries <: AbstractVector{ImageFrame}
    paths::Vector{String}
    counts::Vector{Int}
    offsets::Vector{Int}          # frames preceding each file
    total::Int
    cache::Union{Nothing,ImageFile}
    cacheindex::Int
    openkwargs::NamedTuple
    closed::Bool
end

Base.size(s::FileSeries) = (s.total,)
Base.IndexStyle(::Type{FileSeries}) = IndexLinear()

"""
    seriesfiles(series) -> Vector{String}

The paths making up the series, in order.
"""
seriesfiles(s::FileSeries) = copy(s.paths)

"""
    framesperfile(series) -> Vector{Int}
"""
framesperfile(s::FileSeries) = copy(s.counts)

"""
    open_series(paths; kwargs...) -> FileSeries
    open_series(; first, last=nothing, count=nothing, step=1, kwargs...) -> FileSeries
    open_series(f::Function, args...; kwargs...)

Open several files as one series of frames. `kwargs` are passed to [`openimage`](@ref).

```julia
series = Fabio.open_series(first = "200mMmgso4_001.mar2300")
series[1][1024, 1024]
series[2].source                  # …_002.mar2300
length(series)

Fabio.open_series(first = "foobar_0000.edf") do series
    frame1, frame100 = series[1], series[100]
end
```

Every file's headers are read at this point, since the frame counts are what make a single
index across the series meaningful. No pixel data is read.
"""
function open_series(paths::AbstractVector{<:AbstractString}; kwargs...)
    isempty(paths) && throw(ArgumentError("a series needs at least one file"))
    ps = String[String(p) for p in paths]
    counts = Vector{Int}(undef, length(ps))
    offsets = Vector{Int}(undef, length(ps))
    running = 0
    for (i, p) in enumerate(ps)
        isfile(p) || throw(ArgumentError("no such file in the series: $p"))
        offsets[i] = running
        n = openimage(length, p; kwargs...)
        counts[i] = n
        running += n
    end
    return FileSeries(ps, counts, offsets, running, nothing, 0, NamedTuple(kwargs), false)
end

function open_series(;
    first::AbstractString,
    last::Union{Nothing,AbstractString} = nothing,
    count::Union{Nothing,Integer} = nothing,
    step::Integer = 1,
    kwargs...,
)
    return open_series(
        seriespaths(first; last = last, count = count, step = step);
        kwargs...,
    )
end

function open_series(f::Function, args...; kwargs...)
    series = open_series(args...; kwargs...)
    try
        return f(series)
    finally
        close(series)
    end
end

function Base.close(s::FileSeries)
    s.closed && return nothing
    s.cache === nothing || close(s.cache)
    s.cache = nothing
    s.cacheindex = 0
    s.closed = true
    return nothing
end

"""Open file `i` of the series if it is not already the one in hand."""
function _seriesfile(s::FileSeries, i::Int)
    s.closed && throw(ArgumentError("this series has been closed"))
    s.cacheindex == i && s.cache !== nothing && return s.cache
    s.cache === nothing || close(s.cache)
    s.cache = openimage(s.paths[i]; s.openkwargs...)
    s.cacheindex = i
    return s.cache
end

function Base.getindex(s::FileSeries, i::Int)
    @boundscheck checkbounds(s, i)
    fi = searchsortedlast(s.offsets, i - 1)
    file = _seriesfile(s, fi)
    local_i = i - s.offsets[fi]
    frame = file[local_i]
    # The frame knows where it sits in its own file; the series index is this layer's to set.
    return ImageFrame(
        data(frame),
        header(frame);
        fileindex = frame.fileindex,
        seriesindex = i,
        source = frame.source,
        format = frame.format,
    )
end

function Base.show(io::IO, ::MIME"text/plain", s::FileSeries)
    print(io, "FileSeries: ", s.total, " frame", s.total == 1 ? "" : "s")
    print(io, " across ", length(s.paths), " file", length(s.paths) == 1 ? "" : "s")
    isempty(s.paths) || print(io, ", ", basename(first(s.paths)), " …")
    s.closed && print(io, " [closed]")
end

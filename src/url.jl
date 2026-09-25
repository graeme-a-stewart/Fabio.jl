"""
    SliceRange(start, stop, step)

One `start:stop:step` element of a [`DataUrl`](@ref) slice, with numpy's meaning: **0-based**,
`stop` exclusive, negative values counting from the end, and any part `nothing` when it was
left out (`"::2"` is `SliceRange(nothing, nothing, 2)`).

It is kept exactly as written rather than converted to a Julia range, because a URL is text
shared with silx and other Python tools, and it has to mean the same thing in all of them.
[`juliaindices`](@ref) does the conversion, once the dimensions it applies to are known.
"""
struct SliceRange
    start::Union{Nothing,Int}
    stop::Union{Nothing,Int}
    step::Union{Nothing,Int}
end

SliceRange() = SliceRange(nothing, nothing, nothing)

"""
    SliceEllipsis()

The `...` of a [`DataUrl`](@ref) slice: as many whole axes as it takes to make the slice span
every dimension, as in numpy.
"""
struct SliceEllipsis end

"""One element of a [`DataUrl`](@ref) slice."""
const SliceElement = Union{Int,SliceRange,SliceEllipsis}

"""
    DataUrl(text)
    DataUrl(; file_path, data_path=nothing, data_slice=nothing, scheme=nothing)

A reference to data: a file, optionally a path inside it, and optionally a slice. This is
silx's `silx.io.url.DataUrl`, and parses the same strings to the same parts:

```julia
DataUrl("fabio:///data/image.edf?slice=2")            # frame 2, counting from 0
DataUrl("silx:///data/image.h5?path=/entry/data&slice=1,5")
DataUrl("silx:///data/image.h5?/entry/data")          # `path=` may be left out…
DataUrl("silx:///data/image.h5::/entry/data")         # …and `::` can stand in for `?`
DataUrl("/data/image.h5::path=/entry/data&slice=0")   # no scheme: either reader may serve it
DataUrl("fabio:image.edf")                            # relative paths
DataUrl("C:/data/image.edf")                          # a Windows drive is not a scheme
```

The schemes are `fabio` (read through the image readers, the slice picking a frame), `silx`
(read through a path inside the file) and `http`/`https` (an HSDS server, which this package
recognises but cannot read). An unknown scheme parses, but gives an invalid URL.

# Slices are 0-based

A slice is stored as written: numpy syntax, 0-based, `stop` exclusive, axes listed slowest
first. `DataUrl("f.h5?path=/d&slice=0")` is the *first* frame. That keeps a URL meaning the same
thing whichever tool reads it; [`juliaindices`](@ref) converts it to Julia indices in this
package's `(fast, slow, …)` order.

# Validity

A URL that cannot be understood still constructs, as in silx; `isvalid(url)` says whether it
can be used and [`invalidreason`](@ref) says why not. [`getdata`](@ref) refuses an invalid URL.

# Accessors

[`scheme`](@ref), [`filepath`](@ref), [`datapath`](@ref), [`dataslice`](@ref),
[`isabsolute`](@ref), [`invalidreason`](@ref); `string(url)` gives the canonical text form.
"""
struct DataUrl
    text::Union{Nothing,String}
    scheme::Union{Nothing,String}
    file_path::Union{Nothing,String}
    data_path::Union{Nothing,String}
    data_slice::Union{Nothing,Tuple{Vararg{SliceElement}}}
    invalid_reason::Union{Nothing,String}
end

"""The schemes silx accepts."""
const URL_SCHEMES = ("fabio", "silx", "http", "https")

function DataUrl(;
    file_path::Union{Nothing,AbstractString} = nothing,
    data_path::Union{Nothing,AbstractString} = nothing,
    data_slice = nothing,
    scheme::Union{Nothing,AbstractString} = nothing,
)
    fp = file_path === nothing ? nothing : String(file_path)
    dp = data_path === nothing ? nothing : String(data_path)
    sl = _sliceelements(data_slice)
    sc = scheme === nothing ? nothing : String(scheme)
    return DataUrl(nothing, sc, fp, dp, sl, _urlproblem(sc, fp, dp, sl))
end

_sliceelements(::Nothing) = nothing
_sliceelements(s::SliceElement) = (s,)
_sliceelements(s::Integer) = (Int(s),)
_sliceelements(s::Union{Tuple,AbstractVector}) =
    Tuple(x isa Integer ? Int(x) : x::Union{SliceRange,SliceEllipsis} for x in s)

"""Why a URL with these parts is invalid, or `nothing`. silx's `__check_validity`."""
function _urlproblem(scheme, file_path, data_path, data_slice)
    (file_path === nothing || isempty(file_path)) && return "Invalid file path"
    scheme === nothing || scheme in URL_SCHEMES ||
        return "Invalid scheme. It can only be $(join(URL_SCHEMES, ", "))."
    scheme == "fabio" && data_path !== nothing && return "fabio URLs cannot have a data path"
    scheme == "silx" && data_slice !== nothing && data_path === nothing &&
        return "silx URLs cannot have a slice with no data path"
    return nothing
end

function DataUrl(text::AbstractString)
    original = String(text)
    s = occursin('?', original) ? original : replace(original, "::" => "?"; count = 1)
    urlscheme, netloc, path, query = _urlsplit(s)

    if length(urlscheme) <= 2
        # No scheme, or a Windows drive letter that looked like one: the file path is
        # everything up to the start of the parsed path, plus the path.
        scheme = nothing
        pos = findfirst(path, original)       # an empty path is found at the start, as in Python
        file_path = pos === nothing ? path : original[1:prevind(original, first(pos))] * path
    else
        scheme = urlscheme
        file_path = netloc * path
        # `fabio:///C:/data` parses with a leading slash in front of the drive letter.
        c = _firstchars(file_path)
        if length(c) > 2 && c[1] == '/' && (c[2] == ':' || c[3] == ':')
            file_path = file_path[2:end]
        end
    end

    pairs = _parseqsl(query)
    data_path = nothing
    data_slice = nothing
    problem = nothing
    if length(pairs) == 1 && isempty(pairs[1][2])
        # No keys at all: the whole query is the data path.
        data_path = pairs[1][1]
    else
        merged = Dict{String,String}()
        for (k, v) in pairs
            haskey(merged, k) &&
                @warn "More than one query key named '$k' in URL $(repr(original)). The last one is used."
            merged[k] = v
        end
        data_path = pop!(merged, "path", nothing)
        rawslice = pop!(merged, "slice", nothing)
        if rawslice !== nothing
            data_slice = _parseslice(rawslice)
            data_slice === nothing && (problem = "Invalid slice")
        end
        for k in sort!(collect(keys(merged)))
            @warn "Query key $(repr(k)) unsupported in URL $(repr(original)). Key skipped."
        end
    end

    problem === nothing && (problem = _urlproblem(scheme, file_path, data_path, data_slice))
    return DataUrl(original, scheme, file_path, data_path, data_slice, problem)
end

"""The first three characters of `s`: indexing by character, as Python does, not by byte."""
_firstchars(s::AbstractString) = collect(Iterators.take(s, 3))

"""
    _urlsplit(s) -> (scheme, netloc, path, query)

The subset of Python's `urllib.parse.urlsplit` that silx relies on. The scheme is lowercased
and must start with a letter; a network location follows `//`. Unlike Python, `#` is not
treated as the start of a fragment, since it is a legal character in file names and silx has
no use for fragments.
"""
function _urlsplit(s::String)
    scheme = ""
    rest = s
    i = findfirst(':', s)
    if i !== nothing && i > 1 && isletter(s[1]) &&
       all(c -> isascii(c) && (isletter(c) || isdigit(c) || c in "+-."), s[1:prevind(s, i)])
        scheme = lowercase(s[1:prevind(s, i)])
        rest = s[nextind(s, i):end]
    end
    netloc = ""
    if startswith(rest, "//")
        rest = rest[3:end]
        j = findfirst(c -> c == '/' || c == '?', rest)
        netloc = j === nothing ? rest : rest[1:prevind(rest, j)]
        rest = j === nothing ? "" : rest[j:end]
    end
    q = findfirst('?', rest)
    path = q === nothing ? rest : rest[1:prevind(rest, q)]
    query = q === nothing ? "" : rest[nextind(rest, q):end]
    return (scheme, netloc, path, query)
end

"""Python's `parse_qsl(query, keep_blank_values=True)`: `&`-separated, `+` and `%XX` decoded."""
function _parseqsl(query::AbstractString)
    out = Tuple{String,String}[]
    for field in split(query, '&')
        isempty(field) && continue
        k, v = occursin('=', field) ? split(field, '='; limit = 2) : (field, "")
        push!(out, (_unquoteplus(k), _unquoteplus(v)))
    end
    return out
end

function _unquoteplus(s::AbstractString)
    occursin('%', s) || occursin('+', s) || return String(s)
    out = UInt8[]
    b = codeunits(s)
    i = 1
    while i <= length(b)
        c = b[i]
        if c == UInt8('+')
            push!(out, UInt8(' '))
        elseif c == UInt8('%') && i + 2 <= length(b)
            v = tryparse(UInt8, String(b[i+1:i+2]); base = 16)
            if v !== nothing
                push!(out, v)
                i += 3
                continue
            end
            push!(out, c)
        else
            push!(out, c)
        end
        i += 1
    end
    return String(out)
end

"""Parse `"1,2:5,::2,..."` into slice elements, or `nothing` if it is not a valid slice."""
function _parseslice(text::AbstractString)
    isempty(text) && return nothing
    elements = SliceElement[]
    for token in split(text, ',')
        e = _parseslicetoken(token)
        e === nothing && return nothing
        push!(elements, e)
    end
    return Tuple(elements)
end

function _parseslicetoken(token::AbstractString)
    token == "..." && return SliceEllipsis()
    occursin(':', token) || return _pyint(token)
    token == ":" && return SliceRange()
    parts = split(token, ':')
    values = Union{Nothing,Int}[]
    for p in parts[1:min(3, end)]
        if isempty(p)
            push!(values, nothing)
        else
            v = _pyint(p)
            v === nothing && return nothing
            push!(values, v)
        end
    end
    while length(values) < 3
        push!(values, nothing)
    end
    return SliceRange(values[1], values[2], values[3])
end

"""Python's `int(text)`: surrounding whitespace, a sign and digit-group underscores allowed."""
function _pyint(text::AbstractString)
    t = strip(text)
    (isempty(t) || occursin("__", t) || startswith(t, '_') || endswith(t, '_')) && return nothing
    return tryparse(Int, replace(t, '_' => ""))
end

# ------------------------------------------------------------------------ accessors

"""
    scheme(url) -> Union{Nothing,String}

`"fabio"`, `"silx"`, `"http"`, `"https"`, or `nothing` when the URL names none.
"""
scheme(u::DataUrl) = u.scheme

"""
    filepath(url) -> Union{Nothing,String}

The file the URL points into.
"""
filepath(u::DataUrl) = u.file_path

"""
    datapath(url) -> Union{Nothing,String}

The path inside the file, or `nothing`.
"""
datapath(u::DataUrl) = u.data_path

"""
    dataslice(url) -> Union{Nothing,Tuple}

The slice, as a tuple of `Int`, [`SliceRange`](@ref) and [`SliceEllipsis`](@ref), 0-based and
in numpy axis order, exactly as written. See [`juliaindices`](@ref) to use it.
"""
dataslice(u::DataUrl) = u.data_slice

"""
    invalidreason(url) -> Union{Nothing,String}

Why the URL is invalid, in silx's words, or `nothing` if it is valid.
"""
invalidreason(u::DataUrl) = u.invalid_reason

"""
    isvalid(url::DataUrl) -> Bool

Whether the URL can be used. See [`invalidreason`](@ref).
"""
Base.isvalid(u::DataUrl) = u.invalid_reason === nothing

"""
    isabsolute(url) -> Bool

Whether the file path is absolute, by POSIX or Windows rules (`/data`, `C:/data`), whichever
platform this runs on — a URL may name a file on another machine.
"""
function isabsolute(u::DataUrl)
    u.file_path === nothing && return false
    c = _firstchars(u.file_path)
    isempty(c) && return false
    c[1] == '/' && return true
    length(c) > 2 && return c[2] == ':' || c[3] == ':'
    length(c) > 1 && return c[2] == ':'
    return false
end

function Base.:(==)(a::DataUrl, b::DataUrl)
    isvalid(a) == isvalid(b) || return false
    isvalid(a) || return urlstring(a) == urlstring(b)
    return a.scheme == b.scheme && a.file_path == b.file_path && a.data_path == b.data_path &&
           a.data_slice == b.data_slice
end

Base.hash(u::DataUrl, h::UInt) =
    isvalid(u) ? hash((u.scheme, u.file_path, u.data_path, u.data_slice), h) :
    hash(urlstring(u), h)

"""
    urlstring(url) -> String

The text form of a URL: what it was parsed from, or for one built from its parts, the
canonical form silx's `DataUrl.path()` produces. `string(url)` is the same.
"""
function urlstring(u::DataUrl)
    u.text === nothing || return u.text
    query = if u.data_path !== nothing && u.data_slice === nothing
        u.data_path
    else
        q = String[]
        u.data_path === nothing || push!(q, "path=" * u.data_path)
        u.data_slice === nothing || push!(q, "slice=" * slicestring(u.data_slice))
        join(q, "&")
    end
    path = something(u.file_path, "")
    isempty(query) || (path *= "?" * query)
    if u.scheme !== nothing
        path = if isabsolute(u)
            startswith(path, '/') ? u.scheme * "://" * path : u.scheme * ":///" * path
        else
            u.scheme * "://" * path
        end
    end
    return path
end

"""
    slicestring(slice) -> String

A slice in URL syntax: `(1, SliceRange(nothing, 2, 3))` gives `"1,:2:3"`.
"""
slicestring(s::Tuple) = join(map(slicestring, s), ",")
slicestring(i::Int) = string(i)
slicestring(::SliceEllipsis) = "..."
function slicestring(s::SliceRange)
    out = s.start === nothing ? ":" : string(s.start, ":")
    s.stop === nothing || (out *= string(s.stop))
    s.step === nothing || (out *= string(":", s.step))
    return out
end

Base.print(io::IO, u::DataUrl) = print(io, urlstring(u))
Base.show(io::IO, u::DataUrl) = print(io, "DataUrl(", repr(urlstring(u)), ")")

function Base.show(io::IO, ::MIME"text/plain", u::DataUrl)
    println(io, "DataUrl(", repr(urlstring(u)), ")")
    println(io, "  scheme    : ", something(u.scheme, "—"))
    println(io, "  file path : ", something(u.file_path, "—"))
    println(io, "  data path : ", something(u.data_path, "—"))
    print(io, "  slice     : ", u.data_slice === nothing ? "—" : slicestring(u.data_slice))
    isvalid(u) || print(io, "\n  INVALID   : ", u.invalid_reason)
end

# ------------------------------------------------------------------------ indexing

"""
    juliaindices(slice, dims) -> Tuple

Convert a URL slice to indices for an array of Julia size `dims`, so that `A[idx...]` selects
what numpy would select with the same slice on the same data.

Two conversions happen. Values go from 0-based to 1-based, with numpy's handling of negative
values, of `stop` being exclusive, of out-of-range bounds (clamped, for a range) and of
negative steps. And axes are reversed: a slice lists axes slowest first, as numpy's `shape`
does, while `dims` is in this package's `(fast, slow, …)` order. So on a `(fast, slow, frame)`
stack, `slice=3` is frame 4, and `slice=3,0` is its first row, `(:, 1, 4)`.

An integer index drops its axis, as in numpy; a range keeps it. An integer out of range
throws `BoundsError`.
"""
function juliaindices(slice::Tuple, dims::Dims)
    nd = length(dims)
    ne = count(x -> x isa SliceEllipsis, slice)
    ne > 1 && throw(ArgumentError("a slice can have only one ellipsis (…), got $(slicestring(slice))"))
    nexplicit = length(slice) - ne
    nexplicit > nd && throw(
        ArgumentError("slice $(slicestring(slice)) has $nexplicit indices for $nd dimensions"),
    )
    expanded = SliceElement[]
    for x in slice
        if x isa SliceEllipsis
            append!(expanded, fill(SliceRange(), nd - nexplicit))
        else
            push!(expanded, x)
        end
    end
    append!(expanded, fill(SliceRange(), nd - length(expanded)))
    npdims = reverse(dims)
    idx = Any[_juliaindex(expanded[a], npdims[a], a) for a = 1:nd]
    return Tuple(reverse(idx))
end

function _juliaindex(i::Int, n::Int, axis::Int)
    j = i < 0 ? i + n : i
    0 <= j < n || throw(BoundsError(1:n, i + 1))
    return j + 1
end

function _juliaindex(s::SliceRange, n::Int, ::Int)
    step = something(s.step, 1)
    step == 0 && throw(ArgumentError("slice step cannot be zero"))
    # Python's slice.indices(n).
    adjust(v, lo, hi) = clamp(v < 0 ? v + n : v, lo, hi)
    if step > 0
        start = s.start === nothing ? 0 : adjust(s.start, 0, n)
        stop = s.stop === nothing ? n : adjust(s.stop, 0, n)
        return (start+1):step:stop
    else
        start = s.start === nothing ? n - 1 : adjust(s.start, -1, n - 1)
        stop = s.stop === nothing ? -1 : adjust(s.stop, -1, n - 1)
        return (start+1):step:(stop+2)
    end
end

# ------------------------------------------------------------------------ reading

"""
    getdata(url) -> Array (or a scalar)

The data a [`DataUrl`](@ref) points at. `url` may also be given as a string. This is silx's
`silx.io.get_data`, and follows its rules for each scheme:

- **`fabio:`** — the file is read by this package's image readers. The URL has no data path;
  its slice is a single integer choosing the frame, **counting from 0**, and defaults to the
  first. Returns the frame's pixels.
- **`silx:`** — the data path names a dataset inside the file, and the slice (if any) selects
  from it. For HDF5 files this needs `using HDF5`. The NeXus view of *image* files that silx
  also offers here is not implemented yet.
- **no scheme** — tried as `silx:`, then as `fabio:`, as silx does.

`http:`/`https:` URLs (HSDS servers) parse, but cannot be read.

The result is an ordinary owned `Array` in this package's `(fast, slow, …)` axis order —
the reverse of the numpy shape silx reports. Use [`readimage`](@ref) with a `DataUrl` to get
the frame's header as well.

```julia
getdata("fabio:///data/series.edf?slice=2")      # the third frame
getdata("/data/scan.h5::/entry/data/data")       # a whole dataset (with `using HDF5`)
getdata("silx:/data/scan.h5?path=/entry/data/data&slice=0")   # its first frame
```
"""
getdata(text::AbstractString) = getdata(DataUrl(text))

function getdata(u::DataUrl)
    isvalid(u) || throw(ArgumentError("URL $(repr(urlstring(u))) is not valid: $(invalidreason(u))"))
    sc = scheme(u)
    sc in ("http", "https") && throw(
        UnsupportedFormatError("URL $(repr(urlstring(u))): reading from HSDS servers is not supported"),
    )
    isfile(filepath(u)) || throw(ArgumentError("no such file: $(filepath(u))"))
    sc == "fabio" && return _getdata_fabio(u)
    sc == "silx" && return _getdata_silx(u)
    errors = String[]
    for (name, f) in (("silx", _getdata_silx), ("fabio", _getdata_fabio))
        if name == "fabio" && datapath(u) !== nothing
            push!(errors, "fabio: fabio URLs cannot have a data path")
            continue
        end
        try
            return f(u)
        catch err
            err isa InterruptException && rethrow()
            push!(errors, "$name: " * sprint(showerror, err))
        end
    end
    throw(
        ArgumentError(
            "data from $(repr(urlstring(u))) is readable neither as silx nor as fabio:\n  " *
            join(errors, "\n  "),
        ),
    )
end

function _getdata_fabio(u::DataUrl)
    i = _urlframe(u)
    return openimage(filepath(u)) do file
        n = length(file)
        # In the URL's terms, not Julia's: the slice was written counting from 0.
        1 <= i <= n || throw(
            ArgumentError(
                "slice $(i - 1) is out of range: $(filepath(u)) has $n frame$(n == 1 ? "" : "s"), " *
                "numbered from 0 in a URL",
            ),
        )
        _own(data(file[i]))
    end
end

"""The 1-based frame a `fabio:` URL's slice picks: a single integer, 0-based, default 0."""
function _urlframe(u::DataUrl)
    s = dataslice(u)
    s === nothing && return 1
    (length(s) == 1 && s[1] isa Int) || throw(
        ArgumentError("a fabio slice must be a single integer frame index, got $(slicestring(s))"),
    )
    return s[1] + 1
end

function _getdata_silx(u::DataUrl)
    dp = datapath(u)
    dp === nothing && throw(ArgumentError("URL $(repr(urlstring(u))) has no data path"))
    # Detection only: scanning the file as an image would refuse an HDF5 file that holds no
    # image-shaped dataset, which a data path can still address.
    src = opensource(filepath(u))
    fmt = try
        detectformat(src; path = filepath(u))
    finally
        close(src)
    end
    return getdataset(fmt, filepath(u), dp, dataslice(u))
end

"""
    getdataset(fmt, file, datapath, slice)

Read `datapath` from inside `file` (already identified as `fmt`), applying the URL `slice`
(or `nothing` for all of it). The `silx:` half of [`getdata`](@ref).

The HDF5 extension adds the method for `NexusLike`. For every other format the answer
belongs to the NeXus view of image files, which does not exist yet, so this fallback explains
what does work instead.
"""
function getdataset(fmt::ImageFormat, file::AbstractString, datapath::AbstractString, slice)
    fmt isa NexusLike && throw(
        UnsupportedFormatError("file $(repr(file)) is HDF5; run `using HDF5` to read a data path from it"),
    )
    throw(
        UnsupportedFormatError(
            "reading a data path ($(repr(datapath))) from a $(nameof(typeof(fmt))) file is not " *
            "supported yet; use a fabio: URL (e.g. \"fabio:$(file)?slice=0\") to read its frames",
        ),
    )
end

"""
    readimage(url::DataUrl; kwargs...) -> ImageFrame

Read the frame a URL points at, with its header. The URL's data path, if any, becomes the
`::` in-container address, and its slice must be a single frame index (0-based, as in every
URL). `readimage(DataUrl("fabio:a.edf?slice=2"))` is `readimage("a.edf"; frame = 3)`.
"""
function readimage(u::DataUrl; kwargs...)
    isvalid(u) || throw(ArgumentError("URL $(repr(urlstring(u))) is not valid: $(invalidreason(u))"))
    scheme(u) in ("http", "https") && throw(
        UnsupportedFormatError("URL $(repr(urlstring(u))): reading from HSDS servers is not supported"),
    )
    path = datapath(u) === nothing ? filepath(u) : filepath(u) * "::" * datapath(u)
    return readimage(path; frame = _urlframe(u), kwargs...)
end

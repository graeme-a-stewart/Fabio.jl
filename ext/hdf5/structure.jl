# Working out what an HDF5 file is, and which datasets in it hold images.

# ------------------------------------------------------------------ small HDF5 helpers

"""Read attribute `name` on `obj` as a `String`, or `nothing` if it is absent or not text."""
function _attrstring(obj, name::AbstractString)
    a = HDF5.attrs(obj)
    haskey(a, name) || return nothing
    v = try
        a[name]
    catch
        return nothing
    end
    v isa AbstractString && return String(v)
    v isa AbstractVector && !isempty(v) && v[1] isa AbstractString && return String(v[1])
    return nothing
end

"""
Whether `path` resolves inside `h`.

Walked one component at a time rather than handed to `haskey` whole, because a missing
intermediate group is an ordinary outcome here, not an error worth an exception.
"""
function _exists(h, path::AbstractString)
    node = h
    for part in split(strip(path, '/'), '/')
        isempty(part) && continue
        (node isa HDF5.File || node isa HDF5.Group) || return false
        haskey(node, String(part)) || return false
        node = node[String(part)]
    end
    return true
end

"""Resolve `path` inside `h`, or `nothing` if any component is missing."""
function _lookup(h, path::AbstractString)
    _exists(h, path) || return nothing
    return h[String(path)]
end

"""Read a scalar string dataset, tolerating both fixed- and variable-length storage."""
function _datasetstring(h, path::AbstractString)
    ds = _lookup(h, path)
    ds isa HDF5.Dataset || return nothing
    v = try
        read(ds)
    catch
        return nothing
    end
    v isa AbstractString && return String(v)
    v isa AbstractVector && !isempty(v) && v[1] isa AbstractString && return String(v[1])
    return nothing
end

"""Element types this package will treat as pixel data."""
_isimageeltype(::Type{T}) where {T<:Union{Integer,AbstractFloat}} = true
_isimageeltype(::Type) = false

"""Whether `ds` has the shape and type of an image or an image stack."""
function _isimagedataset(ds)
    ds isa HDF5.Dataset || return false
    T = try
        eltype(ds)
    catch
        return false
    end
    _isimageeltype(T) || return false
    n = try
        length(size(ds))
    catch
        return false
    end
    return n == 2 || n == 3
end

"""Every image-shaped dataset in the file, as `path => dataset`, depth first and name sorted."""
function _imagedatasets(h, prefix::AbstractString = "", found = Pair{String,Any}[])
    node = prefix == "" ? h : h[prefix]
    for name in sort(collect(keys(node)))
        path = prefix * "/" * name
        child = try
            node[name]
        catch
            continue
        end
        if child isa HDF5.Group
            _imagedatasets(h, path, found)
        elseif _isimagedataset(child)
            push!(found, path => child)
        end
    end
    return found
end

# --------------------------------------------------------------------------- detection

"""
Resolve an HDF5 file to the member of the family that can read it.

This is the [`Fabio.refine`](@ref) hook doing what FabIO does inside `_do_magic`, where the
magic table holds the composite string `"eiger/lima/sparse/hdf5/lambda"` and a branch picks
one apart. The order of the tests is FabIO's, so the same file resolves the same way.

Declining (returning `nothing`) is possible here in a way it is not in FabIO: an in-memory
buffer has no path for the HDF5 library to open, and a file that cannot be opened at all is
better handed back to detection than claimed and then failed on.
"""
function Fabio.refine(
    ::NexusLike{:unknown},
    ::AbstractVector{UInt8},
    path::Union{Nothing,AbstractString},
    src::AbstractSource,
)
    # A buffer with no path is still recognisably HDF5, so the family claims it and `scan`
    # explains that the HDF5 library has nothing to open. Declining here would instead report
    # that nothing matched, which is untrue — the magic number did.
    file = sourcepath(src)
    (path === nothing || file === nothing) && return NexusLike{:unknown}()
    # An explicit `file.h5::/group/dataset` says the user has already chosen the dataset.
    sourcefragment(src) === nothing || return NexusLike{:hdf5}()
    return try
        HDF5.h5open(file, "r") do h
            _classify(h)
        end
    catch
        nothing
    end
end

function _classify(h)
    creator = something(_attrstring(h, "creator"), "")
    if startswith(creator, "LIMA")
        return _lima_or_sparse(h)
    elseif startswith(creator, "pyFAI")
        return NexusLike{:sparse}()
    end
    if _datasetstring(h, "/entry/instrument/detector/description") == "Lambda"
        return NexusLike{:lambda}()
    end
    # FabIO stops here and calls everything else Eiger, which then fails inside `read` with
    # "HDF5 file does not contain an Eiger-like structure". Checking first costs one lookup
    # and lets a file that is merely HDF5 fall through to the generic reader below.
    isempty(_eigerdatasets(h)) || return NexusLike{:eiger}()
    return NexusLike{:hdf5}()
end

"""A LImA file is sparse if the NXdata it points at declares a Bragg `dataformat`."""
function _lima_or_sparse(h)
    entryname = _attrstring(h, "default")
    entryname === nothing && return NexusLike{:lima}()
    entry = _lookup(h, entryname)
    entry === nothing && return NexusLike{:lima}()
    grpname = _attrstring(entry, "default")
    grpname === nothing && return NexusLike{:lima}()
    grp = startswith(grpname, "/") ? _lookup(h, grpname) : _lookup(entry, grpname)
    grp === nothing && return NexusLike{:lima}()
    fmt = something(_attrstring(grp, "dataformat"), "")
    return occursin("Bragg", fmt) ? NexusLike{:sparse}() : NexusLike{:lima}()
end

# --------------------------------------------------------------- locating the datasets

"""
The image datasets of an Eiger file, in frame order.

Eiger has written two layouts over the years and FabIO reads both: the current one puts
`data_000001`, `data_000002`, … in an `/entry/data` group, while the older one puts
`data_01`, `data_02`, … directly in `/entry`. A single `/entry/data` dataset is also allowed.
"""
function _eigerdatasets(h)
    out = Pair{String,Any}[]
    entry = _lookup(h, "/entry")
    entry isa HDF5.Group || return out
    if haskey(entry, "data")
        node = entry["data"]
        if node isa HDF5.Group
            for name in sort(filter(startswith("data"), collect(keys(node))))
                child = node[name]
                _isimagedataset(child) && push!(out, "/entry/data/" * name => child)
            end
        elseif _isimagedataset(node)
            push!(out, "/entry/data" => node)
        end
    else
        for name in sort(filter(startswith("data"), collect(keys(entry))))
            child = entry[name]
            _isimagedataset(child) && push!(out, "/entry/" * name => child)
        end
    end
    return out
end

"""
The dataset a generic HDF5 file means, resolved in decreasing order of authority:

1. the `::` fragment the caller supplied — always wins;
2. the NeXus `default` attribute chain, root → entry → `NXdata`, which is what the standard
   says a file should use to nominate its plottable data;
3. the file's only image-shaped dataset, if it has exactly one.

FabIO implements only the first of these and makes it mandatory, raising "the '::' separator
is mandatory for HDF5 container" otherwise. Two and three cost little and mean that a file
which is unambiguous does not need to be told what it obviously contains. When the file *is*
ambiguous the error names every candidate, so the fragment to add is there to copy.
"""
function _genericdataset(h, fragment::Union{Nothing,String}, file::AbstractString)
    if fragment !== nothing
        node = _lookup(h, fragment)
        node === nothing &&
            throw(CorruptFileError("HDF5: no such path \"$fragment\" in $file"))
        # FabIO descends into a group's "data" member; a NeXus NXdata group names its own.
        if node isa HDF5.Group
            signal = _attrstring(node, "signal")
            for name in (signal, "data")
                name === nothing && continue
                if haskey(node, name) && _isimagedataset(node[name])
                    return rstrip(fragment, '/') * "/" * name => node[name]
                end
            end
            throw(CorruptFileError("HDF5: \"$fragment\" in $file is a group, not a dataset"))
        end
        _isimagedataset(node) || throw(
            CorruptFileError(
                "HDF5: \"$fragment\" in $file is not a 2-D or 3-D numeric dataset",
            ),
        )
        return String(fragment) => node
    end

    d = _nexusdefault(h)
    d === nothing || return d

    candidates = _imagedatasets(h)
    length(candidates) == 1 && return candidates[1]
    isempty(candidates) &&
        throw(CorruptFileError("HDF5: $file holds no 2-D or 3-D numeric dataset"))
    throw(
        CorruptFileError(
            "HDF5: $file holds " *
            string(length(candidates)) *
            " image datasets; name one with the \"::\" separator, e.g. " *
            "\"" * file * "::" * first(candidates[1]) * "\" " *
            "(candidates: " * join(first.(candidates), ", ") * ")",
        ),
    )
end

"""Follow the NeXus `default` attribute chain to the dataset a file nominates as its signal."""
function _nexusdefault(h)
    entryname = _attrstring(h, "default")
    entryname === nothing && return nothing
    entry = _lookup(h, entryname)
    entry isa HDF5.Group || return nothing
    grpname = _attrstring(entry, "default")
    grpname === nothing && return nothing
    grp = startswith(grpname, "/") ? _lookup(h, grpname) : _lookup(entry, grpname)
    grp isa HDF5.Group || return nothing
    signal = _attrstring(grp, "signal")
    signal === nothing && return nothing
    haskey(grp, signal) || return nothing
    ds = grp[signal]
    _isimagedataset(ds) || return nothing
    return (rstrip(HDF5.name(grp), '/') * "/" * signal) => ds
end

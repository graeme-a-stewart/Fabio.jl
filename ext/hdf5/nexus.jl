# The NeXus metadata around an image: the raw layer, gathered into the header as the file says it.
#
# A NeXus file records its experiment in typed groups — NXdetector, NXbeam, NXsample and so on —
# each field a small dataset, its unit an attribute. None of that is in the image dataset, so
# a reader that returns only pixels leaves the user to reopen the file to learn the wavelength.
# This walks the entry that holds the image and puts those fields into the header, keyed by
# their path, so the raw header is the file's own account and `Fabio.normalise` can work from it.

"""
The NeXus classes whose fields are experiment metadata.

Deliberately a list and not "everything": NXdata holds plottable arrays (the image itself,
usually), NXcollection is a free-for-all that in real files runs to thousands of EPICS process
variables, and NXlog and NXevent_data are time series. What is left is what the NeXus
application definitions — NXmx, NXsas, NXtomo — require of an experiment.
"""
const NEXUS_METADATA_CLASSES = Set([
    "NXentry",
    "NXinstrument",
    "NXdetector",
    "NXdetector_module",
    "NXbeam",
    "NXmonochromator",
    "NXsource",
    "NXsample",
    "NXtransformations",
    "NXattenuator",
    "NXmonitor",
    "NXcollimator",
    "NXaperture",
    "NXslit",
    "NXuser",
])

"""
Arrays up to this length are recorded whole: vectors, orientation matrices, a handful of
per-module values. Anything longer is data, not metadata — a pixel mask, a flat field — and is
left in the file, unless it has exactly one value per frame.
"""
const NEXUS_MAX_ARRAY = 16

"""
    NexusMetadata

What the walk found: `fixed` holds the values true of every frame, `perframe` the arrays that
have one value per frame, still whole, and `detector` the NXdetector group the image belongs
to, when that could be decided.
"""
struct NexusMetadata
    fixed::Header
    perframe::Vector{Pair{String,Any}}
    detector::Union{Nothing,String}
end

NexusMetadata() = NexusMetadata(Header(), Pair{String,Any}[], nothing)

"""A value fit for a header: a number, a string, or a short vector of either."""
function _headervalue(v)
    v isa Union{Number,AbstractString} && return v isa AbstractString ? String(v) : v
    if v isa AbstractArray
        isempty(v) && return nothing
        eltype(v) <: Union{Number,AbstractString} || return nothing
        length(v) == 1 && return _headervalue(first(v))
        return vec(v)
    end
    return nothing
end

"""Read `ds` if it is small enough to be metadata or has one value per frame, else `nothing`."""
function _readmetadata(ds, nframes::Int)
    n = try
        length(ds)
    catch
        return nothing
    end
    (n <= NEXUS_MAX_ARRAY || (nframes > 1 && n == nframes)) || return nothing
    v = try
        read(ds)
    catch
        return nothing
    end
    return _headervalue(v)
end

"""Every attribute of `obj` that makes a header value, as `name => value`."""
function _readattributes(obj)
    out = Pair{String,Any}[]
    names = try
        collect(keys(HDF5.attrs(obj)))
    catch
        return out
    end
    for name in names
        v = try
            _headervalue(HDF5.read_attribute(obj, name))
        catch
            nothing
        end
        v === nothing || push!(out, name => v)
    end
    return out
end

"""
    _nexusmetadata(h, imagepath, image, nframes) -> NexusMetadata

The metadata of the NXentry that holds `imagepath`, or an empty result if it is not in one.

Never throws. Metadata is a convenience on top of the pixels, and a file whose metadata is
damaged or links to a file that is not there must still read.
"""
function _nexusmetadata(h, imagepath::AbstractString, image, nframes::Int)
    try
        parts = split(strip(imagepath, '/'), '/')
        length(parts) >= 2 || return NexusMetadata()
        entrypath = "/" * parts[1]
        entry = _lookup(h, entrypath)
        entry isa HDF5.Group || return NexusMetadata()
        _attrstring(entry, "NX_class") == "NXentry" || return NexusMetadata()
        md = NexusMetadata()
        detectors = String[]
        _walkmetadata!(md, detectors, entry, entrypath, nframes)
        return NexusMetadata(md.fixed, md.perframe, _whichdetector(h, detectors, image))
    catch
        return NexusMetadata()
    end
end

function _walkmetadata!(md, detectors, group, path, nframes)
    class = _attrstring(group, "NX_class")
    md.fixed[path*"@NX_class"] = class
    class == "NXdetector" && push!(detectors, path)
    for name in sort(collect(keys(group)))
        child = try
            _open(group, name)
        catch
            continue    # a dangling link; the image path reports those, metadata does not
        end
        p = path * "/" * name
        if child isa HDF5.Group
            c = _attrstring(child, "NX_class")
            c in NEXUS_METADATA_CLASSES && _walkmetadata!(md, detectors, child, p, nframes)
        elseif child isa HDF5.Dataset
            v = _readmetadata(child, nframes)
            v === nothing && continue
            if nframes > 1 && v isa AbstractVector && length(v) == nframes
                push!(md.perframe, p => v)
            else
                md.fixed[p] = v
            end
            for (a, av) in _readattributes(child)
                md.fixed[p*"@"*a] = av
            end
        end
    end
end

"""
The NXdetector group the image belongs to.

The only one there is, if there is one; otherwise the one holding the image dataset itself,
recognised by object identity because the image is normally reached through a hard link from
an NXdata group. With several detectors and no such link, `nothing` rather than a guess.
"""
function _whichdetector(h, detectors, image)
    length(detectors) == 1 && return detectors[1]
    isempty(detectors) && return nothing
    target = _objectid(image)
    target === nothing && return nothing
    for d in detectors
        g = _lookup(h, d)
        g isa HDF5.Group || continue
        for name in keys(g)
            child = try
                _open(g, name)
            catch
                continue
            end
            child isa HDF5.Dataset && _objectid(child) == target && return d
        end
    end
    return nothing
end

"""
Put `md` into the file header and each frame's header.

The per-frame arrays count frames across the whole entry, as `specs` does, so frame `i` takes
element `i` even when an Eiger file spreads its frames over several datasets.
"""
function _applymetadata!(fileheader::Header, specs::Vector{FrameSpec}, md::NexusMetadata)
    merge!(fileheader, md.fixed)
    md.detector === nothing || (fileheader["HDF5Detector"] = md.detector)
    isempty(md.perframe) && return specs
    return FrameSpec[_withframevalues(s, md.perframe, i) for (i, s) in enumerate(specs)]
end

function _withframevalues(spec::FrameSpec, perframe, i::Int)
    h = copy(spec.header)
    for (k, v) in perframe
        h[k] = v[i]
    end
    return FrameSpec(h, spec.layout)
end

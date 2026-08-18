# Scanning an HDF5 file into frames, and reading one back.

"""
Per-file state for the slice-based readers: the open file, and its datasets resolved once.

`scan` has to open the file to count the frames, and this opens it a second time to keep a
handle for reading. That is deliberate: the alternative is for `scan` to leak a handle into a
value the core would have to know how to close, and an HDF5 open is metadata-only and cheap
next to reading a single detector frame.
"""
mutable struct HDF5State
    file::HDF5.File
    datasets::Dict{String,HDF5.Dataset}
end

const SliceFlavour = Union{
    NexusLike{:eiger},
    NexusLike{:lima},
    NexusLike{:lambda},
    NexusLike{:hdf5},
}

# ------------------------------------------------------------------------------- scan

"""
    scan(::NexusLike, src) -> (Header, Vector{FrameSpec})

Enumerate the frames of an HDF5 container without reading any pixels.

Each flavour differs only in where it looks for the image datasets; once found, they are
turned into [`Fabio.HDF5Slice`](@ref) specs by the same code.
"""
function _scanfile(fmt::NexusLike, src::AbstractSource)
    file = sourcepath(src)
    file === nothing && throw(
        UnsupportedFormatError(
            "HDF5 files are read through the HDF5 library, which needs a path; " *
            "an in-memory buffer cannot be opened as HDF5",
        ),
    )
    return HDF5.h5open(file, "r") do h
        _scan(fmt, h, src, file)
    end
end

# One method per flavour rather than a single `scan(::NexusLike{F}) where {F}`, which would
# have exactly the signature the core already defines for the not-loaded case, and identical
# signatures cannot coexist across a package and its extension.
for flavour in (:eiger, :lima, :lambda, :hdf5, :sparse, :unknown)
    @eval Fabio.scan(fmt::NexusLike{$(QuoteNode(flavour))}, src::AbstractSource) =
        _scanfile(fmt, src)
end

function _scan(::NexusLike{:eiger}, h, src, file)
    datasets = _eigerdatasets(h)
    isempty(datasets) && throw(
        CorruptFileError("HDF5: $file does not contain an Eiger-like structure"),
    )
    return Header(), _specs(datasets, file, Header())
end

function _scan(::NexusLike{:lima}, h, src, file)
    entryname = _attrstring(h, "default")
    entryname === nothing &&
        throw(CorruptFileError("HDF5: $file declares no default entry"))
    entry = _lookup(h, entryname)
    entry isa HDF5.Group ||
        throw(CorruptFileError("HDF5: the default entry \"$entryname\" of $file is missing"))
    ds = _lookup(entry, "measurement/data")
    _isimagedataset(ds) || throw(
        CorruptFileError("HDF5: $file has no measurement/data dataset in $entryname"),
    )
    base = Header()
    # FabIO names the detector from the NXdata the entry points at, taking the second-to-last
    # path component. Absent that it uses the literal "detector".
    nxdata = _attrstring(entry, "default")
    parts = nxdata === nothing ? String[] : split(nxdata, "/")
    base["detector"] = length(parts) >= 2 ? String(parts[end-1]) : "detector"
    path = rstrip(HDF5.name(entry), '/') * "/measurement/data"
    return Header(), _specs([path => ds], file, base)
end

const LAMBDA_DETECTOR_GRP = "/entry/instrument/detector"

function _scan(::NexusLike{:lambda}, h, src, file)
    ds = _lookup(h, LAMBDA_DETECTOR_GRP * "/data")
    _isimagedataset(ds) ||
        throw(CorruptFileError("HDF5: $file has no $(LAMBDA_DETECTOR_GRP)/data dataset"))
    base = Header()
    name = _datasetstring(h, LAMBDA_DETECTOR_GRP * "/local_name")
    base["detector"] = name === nothing ? "detector" : name
    return Header(), _specs([LAMBDA_DETECTOR_GRP * "/data" => ds], file, base)
end

function _scan(::NexusLike{:hdf5}, h, src, file)
    path, ds = _genericdataset(h, sourcefragment(src), file)
    return Header(), _specs([String(path) => ds], file, Header())
end

function _scan(::NexusLike{:unknown}, h, src, file)
    # Only reachable if a caller passes `format = NexusLike{:unknown}()` by hand.
    return _scan(_classify(h), h, src, file)
end

"""
Turn resolved datasets into one [`Fabio.FrameSpec`](@ref) per frame.

HDF5.jl reports a dataset's dimensions in the reverse of the file's C order, so a stack stored
as `(nframes, slow, fast)` arrives here as `(fast, slow, nframes)` — already this package's
axis convention, with the frame index last. A 2-D dataset is a single frame and is marked with
`index = -1`.
"""
function _specs(datasets, file::AbstractString, base::Header)
    specs = FrameSpec[]
    for (path, ds) in datasets
        sz = size(ds)
        T = eltype(ds)
        h = copy(base)
        h["HDF5File"] = String(file)
        h["HDF5Path"] = String(path)
        if length(sz) == 2
            push!(specs, FrameSpec(h, HDF5Slice{T}(String(path), -1, (sz[1], sz[2]))))
        else
            for k = 1:sz[3]
                push!(specs, FrameSpec(h, HDF5Slice{T}(String(path), k - 1, (sz[1], sz[2]))))
            end
        end
    end
    return specs
end

# -------------------------------------------------------------------------- open/close

function Fabio.openstate(
    ::SliceFlavour,
    src::AbstractSource,
    ::Header,
    specs::Vector{FrameSpec},
)
    file = sourcepath(src)
    h = HDF5.h5open(file, "r")
    datasets = Dict{String,HDF5.Dataset}()
    try
        for s in specs
            l = s.layout
            l isa HDF5Slice || continue
            haskey(datasets, l.dataset) && continue
            datasets[l.dataset] = h[l.dataset]
        end
    catch
        close(h)
        rethrow()
    end
    return HDF5State(h, datasets)
end

Fabio.closestate(::NexusLike, state::HDF5State) = close(state.file)
Fabio.closestate(::NexusLike, ::Nothing) = nothing

# ------------------------------------------------------------------------------- read

"""
    readframe(file::ImageFile{<:NexusLike}, i) -> ImageFrame

**The tier-2 read.** One slice of one dataset, handed straight back — the HDF5 library has
already undone the chunking, the filters and any byte-order difference, and the dimension
order it reports is the one this package wants.
"""
function Fabio.readframe(f::ImageFile{<:NexusLike}, i::Int)
    spec = f.frames[i]
    A = _readframedata(f.state, spec.layout)
    return ImageFrame(
        A,
        _frameheader(f, spec),
        fileindex = i,
        seriesindex = i,
        source = f.path,
    )
end

function _readframedata(st::HDF5State, sl::HDF5Slice{T}) where {T}
    ds = st.datasets[sl.dataset]
    raw = try
        sl.index < 0 ? ds[:, :] : ds[:, :, sl.index+1]
    catch err
        throw(_readerror(err, ds, sl))
    end
    # A scalar index usually drops the trailing dimension, but not in every HDF5.jl version.
    A = ndims(raw) == 3 ? reshape(raw, size(raw, 1), size(raw, 2)) : raw
    return A::Matrix{T}
end

"""
Turn a failed dataset read into something the user can act on.

A detector HDF5 file is very often written with a compression filter supplied by a plugin —
bitshuffle and LZ4 for Eiger, blosc elsewhere — and the HDF5 library reports a missing one as
a bare `ErrorException` from deep inside a read. HDF5.jl's own message already names the
filter and the Julia package that provides it, so it is passed through rather than reworded;
what is added is which dataset failed, and the error type this package uses for "recognised
but not readable here".
"""
function _readerror(err, ds, sl::HDF5Slice)
    msg = sprint(showerror, err)
    if occursin("filter", lowercase(msg))
        names = String[]
        try
            for filt in HDF5.Filters.FilterPipeline(HDF5.get_create_properties(ds))
                push!(names, string(HDF5.Filters.filtername(filt)))
            end
        catch
        end
        detail = isempty(names) ? "" : " Dataset filters: " * join(names, ", ") * "."
        return UnsupportedFormatError(
            "HDF5 dataset \"$(sl.dataset)\" needs a compression filter that is not " *
            "loaded.$detail\n" * msg,
        )
    end
    return err
end

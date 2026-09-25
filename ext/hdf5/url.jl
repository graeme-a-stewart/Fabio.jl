# The `silx:` half of `Fabio.getdata`: a dataset by its path inside the file, optionally sliced.

"""
    getdataset(::NexusLike, file, datapath, slice)

Read the dataset at `datapath` from an HDF5 file. With a slice, only the selected hyperslab is
read where HDF5 can express it (forward steps); a reversed or empty range reads the whole
dataset and indexes it in memory. silx refuses a reversed step here outright, because h5py
does; this gives what numpy would give for the same slice on the same data.

Strings come back as `String`s and scalars as scalars, as silx's `h5py_read_dataset` gives
them, and arrays in HDF5.jl's order, which is the reverse of h5py's shape — this package's
`(fast, slow, …)` convention.
"""
function Fabio.getdataset(::NexusLike, file::AbstractString, datapath::AbstractString, slice)
    return h5open(file, "r") do h
        _closingopened() do
            haskey(h, datapath) ||
                throw(ArgumentError("data path $(repr(datapath)) not found in $(repr(file))"))
            obj = _open(h, datapath)
            obj isa HDF5.Dataset ||
                throw(ArgumentError("data path $(repr(datapath)) in $(repr(file)) is not a dataset"))
            slice === nothing && return read(obj)
            dims = size(obj)
            isempty(dims) &&
                throw(ArgumentError("dataset $(repr(datapath)) is a scalar and cannot be sliced"))
            idx = Fabio.juliaindices(slice, dims)
            # Both kinds of indexing drop an axis indexed by an integer, as numpy does.
            hyperslab = all(i -> i isa Int || (step(i) > 0 && !isempty(i)), idx)
            return hyperslab ? obj[idx...] : read(obj)[idx...]
        end
    end
end

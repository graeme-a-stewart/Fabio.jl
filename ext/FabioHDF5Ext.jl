"""
    FabioHDF5Ext

The HDF5 family of detector formats: Eiger, LImA, Lambda, `sparsify-Bragg`, and a generic
reader for any HDF5 file holding a 2-D or 3-D numeric dataset.

Loaded automatically when the user runs `using HDF5`. See `Fabio.NexusLike` for why this lives
in an extension rather than the core, and for the axis-order argument that makes an HDF5
dataset map onto this package's `(fast, slow)` convention without a permutation.

# Tier 2, genuinely

Every other format in this package describes its pixels as a byte range and lets the core do
the reading. An HDF5 dataset cannot be described that way — it is chunked, filtered and
addressed by the HDF5 library — so this is the family the two-tier design in `DESIGN.md` was
written for. `scan` enumerates the frames, `openstate` holds the open file, `readframe` reads
one slice, and `closestate` closes up.
"""
module FabioHDF5Ext

using HDF5
using Fabio
using Fabio:
    AbstractSource,
    CorruptFileError,
    FrameSpec,
    HDF5Slice,
    Header,
    ImageFile,
    ImageFrame,
    NexusLike,
    SparseFrame,
    UnsupportedFormatError,
    _frameheader,
    sourcefragment,
    sourcepath

include("hdf5/structure.jl")
include("hdf5/read.jl")
include("hdf5/sparse.jl")

end # module

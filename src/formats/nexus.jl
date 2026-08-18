"""
    NexusLike{Flavour} <: ImageFormat

The HDF5 family: `NexusLike{:eiger}`, `{:lima}`, `{:lambda}`, `{:sparse}` and `{:hdf5}`, plus
`{:unknown}` for a file recognised as HDF5 before its structure has been examined.

# Why the reader is in an extension

An HDF5 dataset is not a byte range, so unlike every other format here it cannot be described
by a [`BinaryLayout`](@ref) and cannot be served by the source layer at all — it needs the
HDF5 library, and a path to hand it. That library is a large binary dependency which most
users of this package do not want, so the readers live in `ext/FabioHDF5Ext.jl` and appear the
moment the user runs `using HDF5`.

What stays in the core is this type, the magic number, and a [`scan`](@ref) that fails with an
actionable message. Detection therefore still *recognises* an HDF5 file without the extension
loaded; it just cannot read it, and says which incantation would fix that.

# Detection

FabIO puts the composite string `"eiger/lima/sparse/hdf5/lambda"` in its magic table and
resolves it inside `_do_magic` by opening the file and reading the root `creator` attribute.
Here that is [`refine`](@ref)'s job, and the method that does the probing lives in the
extension — so with HDF5 unavailable the family resolves to `{:unknown}` and stops there
rather than raising an import error from inside the detection loop.

# Axis order — an unusually good fit

HDF5 stores datasets in C order, so an image stack has HDF5 shape `(nframes, slow, fast)` and
h5py reports a frame as `(slow, fast)`. HDF5.jl reverses the dimension order when it maps a
dataset into a column-major language, which means it reports that same stack as
`(fast, slow, nframes)`. That is exactly this package's convention (see [`ImageFrame`](@ref)),
so a frame is read out with no permutation and no copy beyond the one the HDF5 library makes.
"""
struct NexusLike{Flavour} <: ImageFormat end

"""HDF5's signature: a high bit, "HDF", and a CRLF/EOF/LF sequence that catches line-ending damage."""
const HDF5_MAGIC = UInt8[0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

"""
    HDF5Slice{T}(dataset, index, dims)

Where one frame lives inside an HDF5 container: which dataset, and which slice of it.

This is to the HDF5 readers what [`BinaryLayout`](@ref) is to a tier-1 format — the difference
being that it addresses a dataset rather than a byte range, which is precisely why this family
needs tier 2. `index` is the 0-based frame index within a 3-D dataset, or `-1` when the
dataset is 2-D and *is* the frame.
"""
struct HDF5Slice{T}
    dataset::String
    index::Int
    dims::Dims{2}
end

Base.eltype(::FrameSpec{HDF5Slice{T}}) where {T} = T
framedims(s::FrameSpec{<:HDF5Slice}) = s.layout.dims

"""
    SparseFrame{T}(index, dims)

One frame of a `sparsify-Bragg` file, which is not stored as pixels at all: the frame is
rebuilt from a background model plus a list of peak intensities. See the `densify` function in
the HDF5 extension.
"""
struct SparseFrame{T}
    index::Int
    dims::Dims{2}
end

Base.eltype(::FrameSpec{SparseFrame{T}}) where {T} = T
framedims(s::FrameSpec{<:SparseFrame}) = s.layout.dims

"""
Fail helpfully when an HDF5 file is opened without the extension loaded.

The extension adds `scan` methods for the concrete flavours, and a [`refine`](@ref) that
resolves `{:unknown}` to one of them, so this method is only ever reached when `HDF5` is not
loaded.
"""
function scan(::NexusLike{F}, src::AbstractSource) where {F}
    name = something(sourcepath(src), "<buffer>")
    throw(
        UnsupportedFormatError(
            "file \"$name\" is HDF5; run `using HDF5` to enable this reader",
        ),
    )
end

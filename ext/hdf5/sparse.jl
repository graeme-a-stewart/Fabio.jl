# The `sparsify-Bragg` format: frames stored as a radial background model plus a list of
# outlier pixels, and rebuilt on read.
#
# This is the one member of the family whose pixels are computed rather than fetched. pyFAI's
# `sparsify-Bragg` throws away everything that looks like background, keeping a radial average
# (and its standard deviation) per frame together with the intensity of every pixel that stood
# out from it. Reading is the inverse: paint the background back on, then scatter the peaks.

"""
Everything needed to rebuild the frames of a sparsified file.

`mask` holds each pixel's distance from the beam centre, with a non-finite value marking a
pixel that was masked out. `radius` is the abscissa of the background profiles, so a pixel's
background is `background_avg` interpolated at that pixel's radius.
"""
struct SparseModel{T,M<:AbstractMatrix}
    mask::Matrix{Float64}
    radius::Vector{Float64}
    background_avg::Union{Nothing,Matrix{Float64}}
    background_std::Union{Nothing,Matrix{Float64}}
    frame_ptr::Vector{Int}
    index::Vector{Int}
    intensity::Vector{T}
    dummy::T
    normalization::Union{Nothing,M}
    cutoff::Union{Nothing,Float64}
    dims::Dims{2}
end

mutable struct SparseState{T,M}
    file::HDF5.File
    model::SparseModel{T,M}
    noisy::Bool
end

# --------------------------------------------------------------------------------- scan

"""
Locate the NXdata group holding the sparse representation.

FabIO looks for an entry named by the root `default` attribute, then for a group named by that
entry's `pyFAI_sparse_frames` attribute, falling back to its `default`.
"""
function _sparsegroup(h, file::AbstractString)
    entryname = _attrstring(h, "default")
    entryname === nothing &&
        throw(CorruptFileError("HDF5: $file declares no default entry"))
    entry = _lookup(h, entryname)
    entry isa HDF5.Group ||
        throw(CorruptFileError("HDF5: the default entry \"$entryname\" of $file is missing"))
    dataname = something(
        _attrstring(entry, "pyFAI_sparse_frames"),
        _attrstring(entry, "default"),
        "",
    )
    isempty(dataname) &&
        throw(CorruptFileError("HDF5: $file names no sparse NXdata group"))
    grp = startswith(dataname, "/") ? _lookup(h, dataname) : _lookup(entry, dataname)
    grp isa HDF5.Group ||
        throw(CorruptFileError("HDF5: the sparse NXdata group \"$dataname\" of $file is missing"))
    return entry, grp
end

function _scan(::NexusLike{:sparse}, h, src, file)
    _, grp = _sparsegroup(h, file)
    for req in ("mask", "frame_ptr", "index", "intensity")
        haskey(grp, req) ||
            throw(CorruptFileError("HDF5: $file has no $req in its sparse NXdata group"))
    end
    mask = grp["mask"]
    dims = size(mask)
    length(dims) == 2 ||
        throw(CorruptFileError("HDF5: the sparse mask in $file is not 2-D"))
    T = eltype(grp["intensity"])
    nframes = length(grp["frame_ptr"]) - 1
    nframes >= 1 ||
        throw(CorruptFileError("HDF5: $file holds no sparse frames"))

    base = Header()
    base["HDF5File"] = String(file)
    base["HDF5Path"] = String(HDF5.name(grp))
    specs = FrameSpec[]
    for i = 1:nframes
        push!(specs, FrameSpec(copy(base), SparseFrame{T}(i - 1, (dims[1], dims[2]))))
    end
    return Header(), specs
end

# --------------------------------------------------------------------------- open/close

function Fabio.openstate(
    ::NexusLike{:sparse},
    src::AbstractSource,
    ::Header,
    ::Vector{FrameSpec},
)
    file = sourcepath(src)
    h = HDF5.h5open(file, "r")
    try
        return SparseState(h, _sparsemodel(h, file), false)
    catch
        close(h)
        rethrow()
    end
end

Fabio.closestate(::NexusLike, state::SparseState) = close(state.file)

function _sparsemodel(h, file::AbstractString)
    entry, grp = _sparsegroup(h, file)
    mask = Float64.(read(grp["mask"]))
    frame_ptr = Int.(vec(read(grp["frame_ptr"])))
    index = Int.(vec(read(grp["index"])))
    intensity = vec(read(grp["intensity"]))
    T = eltype(intensity)

    radius = haskey(grp, "radius") ? Float64.(vec(read(grp["radius"]))) : Float64[]
    bavg = haskey(grp, "background_avg") ? _profiles(read(grp["background_avg"])) : nothing
    bstd = haskey(grp, "background_std") ? _profiles(read(grp["background_std"])) : nothing
    isempty(radius) && (bavg = nothing; bstd = nothing)

    dummy = if haskey(grp, "dummy")
        v = read(grp["dummy"])
        _asscalar(T, v)
    elseif T <: AbstractFloat
        T(NaN)
    else
        zero(T)
    end

    normalization =
        haskey(grp, "normalization") ? Float64.(read(grp["normalization"])) : nothing

    return SparseModel{T,Matrix{Float64}}(
        mask,
        radius,
        bavg,
        bstd,
        frame_ptr,
        index,
        intensity,
        dummy,
        normalization,
        _cutoff(entry),
        size(mask),
    )
end

"""Background profiles arrive as `(nradius, nframes)`; a single profile is widened to a column."""
_profiles(a::AbstractMatrix) = Float64.(a)
_profiles(a::AbstractVector) = reshape(Float64.(a), length(a), 1)

_asscalar(::Type{T}, v::Number) where {T} = T(v)
_asscalar(::Type{T}, v::AbstractArray) where {T} = T(first(v))

"""
The background cut-off recorded by the sparsification, if it can be found.

pyFAI stores its whole configuration as a JSON blob in `sparsify/configuration/data`, of which
exactly one number is wanted. Rather than take a JSON dependency into an extension for a
single scalar — one used only when regenerating noise, which is not reproducible anyway — the
value is picked out directly, and anything unexpected simply leaves the cut-off unset. FabIO
does the same on failure: it logs and carries on with `cutoff = None`.
"""
function _cutoff(entry)
    ds = _lookup(entry, "sparsify/configuration/data")
    ds isa HDF5.Dataset || return nothing
    text = try
        v = read(ds)
        v isa AbstractString ? String(v) : String(first(v))
    catch
        return nothing
    end
    m = match(r"\"cutoff_pick\"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)", text)
    m === nothing && return nothing
    return tryparse(Float64, m.captures[1])
end

# ------------------------------------------------------------------------------ densify

"""
    densify(model, frame; noisy=false) -> Matrix{T}

Rebuild one frame from its sparse representation.

The background is the per-frame radial profile interpolated at each pixel's radius, an integer
result is rounded half away from zero, masked pixels are set to the dummy value, and the peaks
are written over the result at their recorded positions.

That last ordering is worth stating, because **FabIO's two densify implementations disagree
about it**. Its Cython extension fills the dummy first and writes the peaks after, so a peak
recorded at a masked pixel survives; its pure-numpy fallback writes the peaks first and then
overwrites them with the dummy, losing it. The same file therefore densifies differently
depending on whether FabIO's compiled extension was built. This follows the Cython order,
because that is the path a normal FabIO install takes.

With `noisy = true` the background is redrawn from a normal distribution about that profile,
which is what FabIO's `SparseImage.NOISY` does. That path cannot agree with FabIO numerically,
since the two draw from different random number generators; it is for regenerating an image
that *looks* like the original, not for reproducing one.
"""
function densify(m::SparseModel{T}, frame::Int; noisy::Bool = false) where {T}
    npix = length(m.mask)
    dense = Vector{Float64}(undef, npix)

    bavg = m.background_avg
    if bavg === nothing
        fill!(dense, 0.0)
    else
        prof = view(bavg, :, frame + 1)
        @inbounds for i = 1:npix
            dense[i] = _interp(m.mask[i], m.radius, prof)
        end
    end

    bstd = m.background_std
    if noisy && bstd !== nothing
        sprof = view(bstd, :, frame + 1)
        @inbounds for i = 1:npix
            s = _interp(m.mask[i], m.radius, sprof)
            v = max(0.0, dense[i] + s * randn())
            if m.cutoff !== nothing
                v = min(dense[i] + m.cutoff * s, v)
            end
            dense[i] = v
        end
    end

    norm = m.normalization
    if norm !== nothing
        @inbounds for i = 1:npix
            dense[i] *= norm[i]
        end
    end

    out = Array{T}(undef, m.dims)
    @inbounds for i = 1:npix
        out[i] = _tostored(T, dense[i])
    end
    @inbounds for i = 1:npix
        isfinite(m.mask[i]) || (out[i] = m.dummy)
    end

    # The peak list, written last — see the note above on which of FabIO's two densify
    # implementations this follows. `frame_ptr` holds 0-based half-open bounds, and `index` is
    # a flat index into the C-order image, which — the axis order here being the reverse of
    # numpy's — is the same walk as a Julia linear index over `(fast, slow)`. So the only
    # adjustment is 1-based counting.
    lo, hi = m.frame_ptr[frame+1] + 1, m.frame_ptr[frame+2]
    @inbounds for k = lo:hi
        out[m.index[k]+1] = m.intensity[k]
    end
    return out
end

"""`numpy.interp`: piecewise linear, clamped to the end values outside the range, NaN in NaN out."""
function _interp(x::Float64, xp::Vector{Float64}, fp)
    n = length(xp)
    (n == 0 || isnan(x)) && return NaN
    x <= xp[1] && return Float64(fp[1])
    x >= xp[n] && return Float64(fp[n])
    j = searchsortedlast(xp, x)
    j >= n && return Float64(fp[n])
    x0, x1 = xp[j], xp[j+1]
    x1 == x0 && return Float64(fp[j])
    y0, y1 = Float64(fp[j]), Float64(fp[j+1])
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
end

# pyFAI rounds an integer result with `fix(x + 0.5 * sign(x))` — half away from zero, not the
# banker's rounding numpy.round would give, which its source comments on. A non-finite value
# only ever belongs to a masked pixel, which is overwritten with the dummy immediately after.
@inline function _tostored(::Type{T}, v::Float64) where {T<:Integer}
    isfinite(v) || return zero(T)
    return unsafe_trunc(T, trunc(v + 0.5 * sign(v)))
end
@inline _tostored(::Type{T}, v::Float64) where {T} = T(v)

# --------------------------------------------------------------------------------- read

_readframedata(st::SparseState, sf::SparseFrame) = densify(st.model, sf.index; noisy = st.noisy)

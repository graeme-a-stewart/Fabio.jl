"""
    ImageFrame{T,N,A} <: AbstractArray{T,N}

One detector frame: the pixel data together with the metadata it was stored with.

Because `ImageFrame` is an `AbstractArray`, every generic Julia array operation works on it
directly — `mean(frame)`, `maximum(frame)`, `frame .* 2`, `heatmap(frame)` — while
`header(frame)` keeps the metadata within reach.

# Axis order

`size(frame) == (fast, slow)`: the **fast-varying (within-row) detector axis comes first**, so
that the bytes on disk map onto Julia's column-major memory without a permutation. This is the
reverse of numpy's `.shape` as reported by FabIO. Use [`rowmajor`](@ref) for a numpy-ordered
view and [`imageview`](@ref) for a display-ordered `(row, col)` one; both are free views.

# Fields

- `data`: the pixel array (possibly an mmap or `reinterpret` view — see [`data`](@ref))
- `header`: metadata as recorded in the file
- `fileindex`: 1-based index of this frame within its source file
- `seriesindex`: 1-based index within the enclosing file series (equal to `fileindex` for a
  single file)
- `source`: path of the file this frame came from, or `nothing`
"""
struct ImageFrame{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    data::A
    header::Header
    fileindex::Int
    seriesindex::Int
    source::Union{Nothing,String}
    format::Union{Nothing,ImageFormat}
end

function ImageFrame(
    data::AbstractArray{T,N},
    header::Header = Header();
    fileindex::Int = 1,
    seriesindex::Int = fileindex,
    source::Union{Nothing,AbstractString} = nothing,
    format::Union{Nothing,ImageFormat} = nothing,
) where {T,N}
    ImageFrame{T,N,typeof(data)}(
        data,
        header,
        fileindex,
        seriesindex,
        source === nothing ? nothing : String(source),
        format,
    )
end

Base.size(f::ImageFrame) = size(f.data)
Base.IndexStyle(::Type{<:ImageFrame{T,N,A}}) where {T,N,A} = IndexStyle(A)
Base.@propagate_inbounds Base.getindex(f::ImageFrame, i::Int) = f.data[i]
Base.@propagate_inbounds Base.getindex(f::ImageFrame, I::Vararg{Int,N}) where {N} =
    f.data[I...]
Base.@propagate_inbounds Base.setindex!(f::ImageFrame, v, i::Int) = (f.data[i] = v)
Base.@propagate_inbounds Base.setindex!(f::ImageFrame, v, I::Vararg{Int,N}) where {N} =
    (f.data[I...] = v)
Base.parent(f::ImageFrame) = f.data

"""
    data(frame) -> AbstractArray

The bare pixel array, dropping the metadata.

This may be a view onto a memory-mapped file rather than an owned `Array`; call
`collect(data(frame))` (or `Array(...)`) if you need an independent copy that outlives the
open [`ImageFile`](@ref).
"""
data(f::ImageFrame) = f.data

"""
    header(frame) -> Header

Metadata recorded with this frame.
"""
header(f::ImageFrame) = f.header

"""
    imageformat(frame) -> Union{Nothing,ImageFormat}

The format this frame was read from, or `nothing` for one built by hand.

Knowing where a frame came from is what lets [`convertimage`]() tell the metadata of the
experiment from the keys that merely describe how *this* file stored its pixels, and drop the
second kind on the way out. FabIO gets the same information from the frame's class, its images
being format objects; here the frame is a plain array, so it carries the format instead.
"""
imageformat(f::ImageFrame) = f.format

"""
    rowmajor(frame)

A zero-copy view in numpy/FabIO axis order, i.e. `(slow, fast)`. Use when porting Python code
that indexes `img.data[row, col]`.
"""
rowmajor(f::ImageFrame{T,2}) where {T} = PermutedDimsArray(f.data, (2, 1))
rowmajor(a::AbstractMatrix) = PermutedDimsArray(a, (2, 1))

"""
    imageview(frame)

A zero-copy view in `(row, col)` order with a top-left origin, matching the convention used by
Images.jl and by matplotlib's `imshow`.

Makie is not one of these: its first array axis is x, so `heatmap(frame)` and `image(frame)`
take the frame itself, unpermuted, and `imageview` would transpose the picture.
"""
imageview(f::ImageFrame{T,2}) where {T} = rowmajor(f)
imageview(a::AbstractMatrix) = rowmajor(a)

function Base.show(io::IO, ::MIME"text/plain", f::ImageFrame{T,N}) where {T,N}
    print(io, join(size(f), "×"), " ImageFrame{", T, "}")
    f.source !== nothing && print(io, " from ", basename(f.source))
    println(io, " (frame ", f.fileindex, "), ", length(f.header), " header entries")
    Base.print_array(io, f.data)
end

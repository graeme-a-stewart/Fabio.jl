"""
    readimage(path; frame=1, kwargs...) -> ImageFrame
    readimage(path, ::Type{T}; frame=1, kwargs...) -> ImageFrame{T}

Read one frame and close the file. `kwargs` are passed to [`openimage`](@ref).

The two-argument form converts to `T` on the way out, which makes the result type stable at
the call site — useful when a pipeline must not be specialised afresh for every file's stored
type.

Because the file is closed before returning, the frame owns its data: unlike a frame taken
from an open [`ImageFile`](@ref), it is never a view onto a memory map.

```julia
frame = Fabio.readimage("image.edf")
mean(frame)
getheader(header(frame), "ESRFCurrent", Float64)
```
"""
function readimage(path::AbstractString; frame::Integer = 1, kwargs...)
    openimage(path; kwargs...) do file
        f = file[frame]
        return ImageFrame(
            _own(data(f)),
            header(f);
            fileindex = f.fileindex,
            seriesindex = f.seriesindex,
            source = f.source,
        )
    end
end

function readimage(path::AbstractString, ::Type{T}; frame::Integer = 1, kwargs...) where {T}
    openimage(path; kwargs...) do file
        f = file[frame]
        return ImageFrame(
            convert(Array{T}, data(f)),
            header(f);
            fileindex = f.fileindex,
            seriesindex = f.seriesindex,
            source = f.source,
        )
    end
end

_own(A::Array) = A
_own(A::AbstractArray) = Array(A)

"""
    readheader(path; frame=1, kwargs...) -> Header

Metadata for one frame, without reading any pixels.
"""
function readheader(path::AbstractString; frame::Integer = 1, kwargs...)
    openimage(path; kwargs...) do file
        return _frameheader(file, file.frames[frame])
    end
end

"""
    readheaders(path; kwargs...) -> Vector{Header}

One header per frame, without reading any pixels.
"""
function readheaders(path::AbstractString; kwargs...)
    openimage(path; kwargs...) do file
        return [_frameheader(file, s) for s in file.frames]
    end
end

"""
    pixeltype(path) -> Type

The stored element type, determined from the header alone.
"""
pixeltype(path::AbstractString; kwargs...) = openimage(pixeltype, path; kwargs...)

"""
    framesize(path; frame=1) -> Dims{2}

The frame dimensions in Julia `(fast, slow)` order, from the header alone.
"""
function framesize(path::AbstractString; frame::Integer = 1, kwargs...)
    openimage(path; kwargs...) do file
        return framedims(file.frames[frame])
    end
end

"""
    framestack(file) -> Array{T,3}

All frames of an open file as one `(fast, slow, frame)` cube.
"""
function framestack(file::ImageFile)
    n = length(file)
    n == 0 && throw(ArgumentError("no frames to stack"))
    first = file[1]
    out = Array{eltype(first)}(undef, size(first)..., n)
    @views copyto!(out[:, :, 1], data(first))
    for i = 2:n
        @views copyto!(out[:, :, i], data(file[i]))
    end
    return out
end

"""
    readframe!(dest, file, i) -> dest

Read frame `i` into a preallocated array, allocating nothing beyond what the codec needs.
The natural inner loop when sweeping a large series.
"""
function readframe!(dest::AbstractArray, file::ImageFile, i::Integer)
    frame = file[Int(i)]
    size(dest) == size(frame) ||
        throw(DimensionMismatch("destination is $(size(dest)), frame is $(size(frame))"))
    copyto!(dest, data(frame))
    return dest
end

"""
    info([io], path)

Print a human-readable summary of a file: format, frames, shape, element type, and header.
The equivalent of FabIO's `fabio_info` application.
"""
info(path::AbstractString) = info(stdout, path)

function info(io::IO, path::AbstractString)
    openimage(path) do file
        println(io, "File        : ", path)
        println(io, "Format      : ", nameof(typeof(file.format)))
        println(io, "Frames      : ", length(file))
        if length(file) > 0 && file.frames[1].layout !== nothing
            l = file.frames[1].layout
            println(io, "Shape       : ", join(l.dims, " × "), "  (fast × slow)")
            println(io, "Element type: ", eltype(l))
            println(io, "Byte order  : ", nameof(typeof(l.byteorder)))
            println(io, "Codec       : ", nameof(typeof(l.codec)))
        end
        file.truncated && println(io, "Status      : TRUNCATED")
        h = _frameheader(file, file.frames[1])
        println(io, "Header      : ", length(h), " entries")
        for (k, v) in h
            s = repr(v)
            length(s) > 60 && (s = s[1:57] * "…")
            println(io, "  ", rpad(k, 32), " ", s)
        end
    end
end

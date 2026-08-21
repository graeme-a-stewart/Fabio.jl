"""
    Magic(pattern, offset = 0)

A byte signature identifying a format. Unlike FabIO's flat table, a `Magic` carries an offset,
so formats whose signature is not at byte 0 need no special casing.
"""
struct Magic
    pattern::Vector{UInt8}
    offset::Int
end
Magic(pattern::AbstractVector{UInt8}) = Magic(Vector{UInt8}(pattern), 0)
Magic(pattern::AbstractString) = Magic(Vector{UInt8}(codeunits(pattern)), 0)
Magic(pattern::AbstractString, offset::Integer) =
    Magic(Vector{UInt8}(codeunits(pattern)), Int(offset))

matches(m::Magic, head::AbstractVector{UInt8}) =
    length(head) >= m.offset + length(m.pattern) &&
    @views head[(m.offset+1):(m.offset+length(m.pattern))] == m.pattern

"""
    FormatEntry

A format's registration record: how to recognise it, what to call it, and what it can do.
"""
struct FormatEntry
    format::ImageFormat
    name::Symbol
    description::String
    extensions::Vector{String}
    magics::Vector{Magic}
    priority::Int
    reader::Bool
    writer::Bool
end

const REGISTRY = FormatEntry[]

"""
    register!(fmt; name, description="", extensions=String[], magic=Magic[],
              priority=0, reader=true, writer=false)

Add a format to the registry. Re-registering the same `name` replaces the previous entry, so a
package may override a built-in reader.

`priority` breaks ties: higher wins, and within equal priority the longest magic pattern wins,
which is what lets a specific detector's TIFF variant outrank plain TIFF without relying on
declaration order.

An out-of-tree format package is nothing more than a `scan` method plus a call to this
function from its `__init__`:

```julia
module MyDetectorFormat
using Fabio
struct MyDetector <: Fabio.ImageFormat end
Fabio.scan(::MyDetector, src) = ...
__init__() = Fabio.register!(MyDetector(); name = :mydetector, extensions = ["mdt"])
end
```
"""
function register!(
    fmt::ImageFormat;
    name::Symbol,
    description::AbstractString = "",
    extensions::AbstractVector{<:AbstractString} = String[],
    magic::AbstractVector{Magic} = Magic[],
    priority::Integer = 0,
    reader::Bool = true,
    writer::Bool = canwrite(fmt),
)
    entry = FormatEntry(
        fmt,
        name,
        String(description),
        String[lowercase(strip(e, '.')) for e in extensions],
        collect(magic),
        Int(priority),
        reader,
        writer,
    )
    i = findfirst(e -> e.name === name, REGISTRY)
    i === nothing ? push!(REGISTRY, entry) : (REGISTRY[i] = entry)
    _sortregistry!()
    return entry
end

function _sortregistry!()
    sort!(
        REGISTRY;
        by = e -> (
            -e.priority,
            -maximum(m -> length(m.pattern), e.magics; init = 0),
            String(e.name),
        ),
    )
    return REGISTRY
end

"""
    formats() -> Vector{FormatEntry}

Every registered format, most specific first.

FabIO maintains its equivalent table by hand in the documentation, and it has drifted: the
published table lists 30 formats while the code registers 37. Generating it from the registry
removes that failure mode.
"""
formats() = copy(REGISTRY)

"""
    formatnames() -> Vector{Symbol}
"""
formatnames() = [e.name for e in REGISTRY]

"""
    findformat(name::Symbol) -> Union{FormatEntry,Nothing}
"""
function findformat(name::Symbol)
    i = findfirst(e -> e.name === name, REGISTRY)
    i === nothing ? nothing : REGISTRY[i]
end

function Base.show(io::IO, ::MIME"text/plain", e::FormatEntry)
    print(io, "FormatEntry(:", e.name, ")")
    isempty(e.description) || print(io, " — ", e.description)
    isempty(e.extensions) || print(io, " [", join("." .* e.extensions, ", "), "]")
    print(io, e.writer ? " (read/write)" : " (read only)")
end

function Base.show(io::IO, ::MIME"text/plain", v::Vector{FormatEntry})
    println(io, length(v), "-element Vector{FormatEntry}:")
    for e in v
        print(io, "  ")
        show(io, MIME"text/plain"(), e)
        println(io)
    end
end

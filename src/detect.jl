"""
Number of leading bytes examined when identifying a file.
"""
const MAGIC_WINDOW = 64

"""
    refine(fmt, head, path, src) -> ImageFormat

Hook allowing a format *family* to resolve itself to a more specific member after its magic
number has matched. This replaces FabIO's practice of putting composite strings such as
`"eiger/lima/sparse/hdf5/lambda"` and `"marccd/tif"` into the magic table and special-casing
them inside the detection function.

Default: the format identifies itself.
"""
refine(fmt::ImageFormat, ::AbstractVector{UInt8}, ::Union{Nothing,AbstractString}, ::AbstractSource) = fmt

"""
    detectformat(src; path=nothing, format=nothing) -> ImageFormat

Identify the format of an open source.

Resolution order, most authoritative first:

1. an explicit `format`,
2. magic-number match, most specific pattern first, then [`refine`](@ref),
3. filename extension (with any compression suffix stripped),

which mirrors FabIO's documented behaviour: "FabIO tries to deduce the actual format from the
file itself and only uses extensions as a fallback if that fails."
"""
function detectformat(
    src::AbstractSource;
    path::Union{Nothing,AbstractString} = nothing,
    format::Union{Nothing,ImageFormat} = nothing,
)
    format === nothing || return format

    n = min(MAGIC_WINDOW, filesize(src))
    head = n > 0 ? Vector{UInt8}(bytes(src, 0, n)) : UInt8[]

    for e in REGISTRY
        e.reader || continue
        for m in e.magics
            if matches(m, head)
                return refine(e.format, head, path, src)
            end
        end
    end

    if path !== nothing
        stem, _ = stripcompression(path)
        ext = lowercase(strip(last(splitext(stem)), '.'))
        if !isempty(ext)
            for e in REGISTRY
                e.reader || continue
                if ext in e.extensions
                    return refine(e.format, head, path, src)
                end
            end
        end
    end

    throw(
        UnknownFormatError(
            path === nothing ? "<buffer>" : String(path),
            "no registered format matched the magic bytes or extension " *
            "(known formats: " * join(string.(formatnames()), ", ") * ")",
        ),
    )
end

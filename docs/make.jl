# Build the documentation.
#
#   julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
#
# HDF5 and FileIO are loaded so that the package extensions are active and their docstrings
# can be included; without them the reference page would silently lose two readers and the
# whole `load`/`save` surface.

using Documenter
using Fabio
using HDF5      # activates FabioHDF5Ext
using FileIO    # activates FabioFileIOExt

# Documenter resolves `@docs` entries as bindings, and an extension module is not one: it is
# reachable only through `Base.get_extension`. Binding the two here is what lets their module
# docstrings — which is where the HDF5 and FileIO designs are written down — appear at all.
const FabioHDF5Ext = Base.get_extension(Fabio, :FabioHDF5Ext)
const FabioFileIOExt = Base.get_extension(Fabio, :FabioFileIOExt)

const REPO = get(ENV, "FABIO_JL_REPO", "github.com/graeme-a-stewart/Fabio.jl")
const BLOB = "https://" * REPO * "/blob/main/"

"""
Stage a Markdown file written for the repository root into `docs/src`.

The README is the single source of truth for the package's narrative, and duplicating it here
would guarantee the two drift. It is copied at build time instead, with its repository-relative
links rewritten: the pages that live beside it become local pages, and the files that stay in
the repository become links into it.
"""
function stage(src::AbstractString, dest::AbstractString)
    text = read(src, String)
    for page in ("validation", "performance", "fabio-py-defects")
        text = replace(text, "](docs/$page.md)" => "]($page.md)")
    end
    for file in ("DESIGN.md", "STATUS.md", "LICENSE", "README.md")
        text = replace(text, "]($file)" => "]($BLOB$file)")
    end
    write(joinpath(@__DIR__, "src", dest), text)
    return dest
end

stage(joinpath(@__DIR__, "..", "README.md"), "index.md")
for page in ("validation.md", "performance.md", "fabio-py-defects.md")
    stage(joinpath(@__DIR__, page), page)
end

makedocs(;
    sitename = "Fabio.jl",
    authors = "Graeme Andrew Stewart",
    modules = [
        Fabio,
        Base.get_extension(Fabio, :FabioHDF5Ext),
        Base.get_extension(Fabio, :FabioFileIOExt),
    ],
    format = Documenter.HTML(;
        canonical = "https://" * replace(REPO, r"^github\.com/([^/]+)/(.*)\.jl$" => s"\1.github.io/\2.jl"),
        # There is no git remote in this checkout, so Documenter cannot work the branch out
        # for itself and would default to "master".
        edit_link = "main",
        repolink = "https://" * REPO,
        sidebar_sitename = false,
    ),
    pages = [
        "Home" => "index.md",
        "Reference" => [
            "Reading" => "reading.md",
            "Writing" => "writing.md",
            "Series and metadata" => "series.md",
            "Formats and extending" => "formats.md",
            "Sources, codecs and errors" => "internals.md",
        ],
        "What was checked" => "validation.md",
        "Performance" => "performance.md",
        "Defects found in FabIO" => "fabio-py-defects.md",
    ],
    checkdocs = :exports,
)

# A no-op outside CI, so running this locally only builds. `FABIO_JL_REPO` overrides the
# repository if the default below is not where this ends up living.
deploydocs(; repo = REPO, devbranch = "main", push_preview = true)

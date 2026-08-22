# Fabio.jl — Architecture & Package Design (v2)

A Julia package reproducing the capability of [fabio](https://github.com/silx-kit/fabio):
read 2D detector images and their metadata from many scientific/X-ray file formats,
returning the pixel data as a Julia `Array` of the correct numerical type.

**v2 changes:** checked against the [FabIO documentation](https://www.silx.org/doc/fabio/latest/)
(read from `doc/source/` in the repo, which is the source of the published site). Every
documented example is now an explicit use case in §16, and three design corrections came out
of that pass. The Esperanto format is worked end-to-end in §15 against real files.

---

## 1. Goals and non-goals

**Goals**

1. `Fabio.readimage("image.edf")` returns pixel data as an `Array{T,2}` with `T` the type actually
   stored in the file (`UInt16`, `Int32`, `Float32`, …) — no silent conversion.
2. Header metadata preserved with original keys, values and ordering.
3. Many formats, discovered automatically from magic bytes and/or filename.
4. Transparent whole-file compression (`.gz`, `.bz2`, `.xz`, `.zst`).
5. In-file data codecs (CBF byte-offset, mar345 PCK, TY1, AGI bitfield, zlib blobs).
6. Multi-frame files and multi-file series.
7. New formats addable in ~100 lines, from inside *or outside* the package.
8. Writers where they make sense, including the numeric coercion that writing implies (§4.3).

**Non-goals (v1)**

- Image processing, azimuthal integration, GUI viewers (pyFAI/silx territory).
- fabio's ambiguous format-dependent `next()` semantics — deliberately dropped, see §4.2.
- Reproducing fabio's numpy axis convention — deliberately diverged, see §7.

---

## 2. What I verified against the documentation

The docs confirmed the model I had derived from the source, corrected three things, and
handed over one design principle almost verbatim.

### Confirmed

| Doc statement | Design consequence |
|---|---|
| "offers a unified interface to their headers (as a python dictionary) and datasets (as a numpy ndarray of integers or floats)" | `Header <: AbstractDict{String,Any}` + `ImageFrame{T} <: AbstractArray{T,2}`. |
| "FabIO just needs a file name to open a file and it determines the file format automatically and deals with gzip and bzip2 compression transparently" | Detection (§6) and container compression (§9) are both invisible to formats. |
| "Information in the header about the binary part of the image (compression, endianness, shape) are interpreted however, other metadata are exposed as they are recorded in the file" | This is exactly the `BinaryLayout` / raw-`Header` split. It settles v1's open question 3: header values stay **as recorded**, with typed accessors on top. |
| "The software is very modular and allows new classes to be added for handling other data formats easily" | The two-tier extension interface (§5) is the Julia rendering of this promise. |
| `nframes`, `shape`, `get_frame(i)`, `frames()` | Matches `length(file)`, `size(frame)`, `file[i]`, iteration. |

### Correction 1 — `convert` is a numeric operation, not just header translation

> "FabIO is capable of converting one image data-format into another by taking care of the
> numerical specifics: for example float arrays are converted to integer arrays if the output
> format only accepts integers."

v1 described `convert` as header key translation only. That is wrong. Formats impose real
constraints on the array itself, and the Esperanto reader proves how far this goes: its `data`
setter rounds floats, casts to `int32`, pads the image to **square, a multiple of 4, clamped
to 256–4096**, and centres it horizontally. The design needs a first-class coercion hook:

```julia
"""
    coerce(fmt, A) -> AbstractArray

Adapt an array to what `fmt` can physically store: element type, and if the format
demands it, shape. Called by `write` and `convert`. Default: identity.
Must be lossless-or-loud — warn via `@info`/`@warn` when information is discarded.
"""
coerce(::ImageFormat, A) = A
coerce(::Esperanto, A) = pad_square_mult4(round_to(Int32, A), 256, 4096)
```

`Fabio.convertimage(frame, fmt)` = `coerce` + header translation, and `Fabio.writeimage` calls `coerce`
so a direct write can never silently produce an invalid file.

### Correction 2 — frames need two indices and a back-link

The sequential-series example in the docs uses four fields on a frame:

```python
frame.data; frame.header
frame.index                    # index inside the file series
frame.file_index               # index inside the source file
frame.file_container.filename  # name of the source file
```

v1's `ImageFrame` had a single `index`. Corrected:

```julia
struct ImageFrame{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    data::A
    header::Header
    fileindex::Int                    # 1-based index within its source file
    seriesindex::Int                  # 1-based index within the enclosing series
    source::Union{Nothing,String}     # path of the source file
end
```

fabio holds the container as a `weakref` (and documents that the link is lost if the user
drops the file object). Julia needs none of that: `ImageFrame` is immutable and owns its
data, so a plain path string is enough and there is no cycle to break.

### Correction 3 — the documented format table is out of date; trust the code

`getting_started.rst` lists 30 formats. `fabioformats._default_codecs` registers 37. The table
omits **dtrek, binary, esperanto, lima, lambda and sparse**. That matters here directly:
Esperanto — the format you have data for — is fully supported in code but absent from the
published table. So: **derive Fabio.jl's format coverage from `_default_codecs`, not from the
docs table**, and generate our own table from the registry (`Fabio.formats()`) so it cannot
drift the same way.

---

## 3. The central architectural divergence from fabio

fabio's design is *class-per-format*: `FabioImage` is simultaneously the reader, the codec,
the file handle, the data container, and the header container; each format subclasses it and
overrides `read`, `_readheader`, `write`. It works, but every format re-implements
"seek to offset, read N bytes, reinterpret as dtype, byteswap, reshape".

Julia has no implementation inheritance, and faking it with abstract types would be the worst
of both worlds. Instead **separate the four concerns fabio conflates**:

| Concern | fabio | Fabio.jl |
|---|---|---|
| Which format is this? | class selection in `openimage` | `ImageFormat` singleton types + registry |
| Where are the bytes? | `_open`, `_need_a_real_file` | `AbstractSource` (mmap / buffer / stream) |
| How are the bytes encoded? | inline per class | `BinaryLayout` + `AbstractDataCodec` |
| What did we read? | the same object, mutated | immutable `ImageFrame <: AbstractArray` |

The payoff: **most formats are "a header, then a typed binary blob"**. Those formats never
write array-decoding code — they parse the header and return a `BinaryLayout` describing the
blob. The core does the rest, once, with mmap and endianness handled in a single place.
§15 shows Esperanto's two on-disk variants (`4BYTE_LONG` and `AGI_BITFIELD`) differing by a
single field of that struct.

---

## 4. Core type model

```julia
# ---- Formats: singleton (or lightly parameterised) marker types -------------
abstract type ImageFormat end

struct EDF       <: ImageFormat end
struct CBF       <: ImageFormat end
struct Mar345    <: ImageFormat end
struct Esperanto <: ImageFormat end
# Families parameterised, so one implementation serves several detectors:
struct TIFFLike{Flavour} <: ImageFormat end      # :plain, :pilatus, :marccd, :hipic
struct NexusLike{Flavour} <: ImageFormat end     # :eiger, :lima, :lambda, :sparse
```

```julia
# ---- Headers ---------------------------------------------------------------
struct Header <: AbstractDict{String,Any}
    dict::OrderedDict{String,Any}    # insertion order preserved (round-trip writing)
    ci::Dict{String,String}          # UPPERCASE -> canonical key, case-insensitive lookup
end

getheader(h, key, ::Type{T})            # typed accessor, throws
getheader(h, key, ::Type{T}, default)   # typed accessor with fallback
```

Values are stored **as recorded in the file** (per the doc statement in §2), with the typed
accessors doing conversion at the point of use. Formats that already parse fields into
numbers — Esperanto's `HEADER_KEYS` scheme decodes by the `l`/`i`/`b`/`d` prefix convention —
add the decoded values *alongside* the raw line, exactly as fabio does.

```julia
# ---- Frames: a matrix that carries its metadata ----------------------------
struct ImageFrame{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    data::A                # Array, mmap view, or reinterpreted view — no copy if avoidable
    header::Header
    fileindex::Int
    seriesindex::Int
    source::Union{Nothing,String}
end

Base.size(f::ImageFrame)           = size(f.data)
Base.getindex(f::ImageFrame, I...) = f.data[I...]
Base.parent(f::ImageFrame)         = f.data
header(f::ImageFrame)              = f.header
```

Subtyping `AbstractArray` means `sum(frame)`, `frame .* 2`, `maximum(frame)`, `heatmap(frame)`
and every generic Julia array algorithm work immediately, while the metadata rides along.
Precedent: `ImageMetadata.ImageMeta`, `AxisArrays`. This is what makes the doc's
`print(image.data.mean())` become simply `mean(frame)`.

```julia
# ---- Binary layout: the contract between a format and the core -------------
abstract type ByteOrder end
struct LittleEndian <: ByteOrder end
struct BigEndian    <: ByteOrder end

struct BinaryLayout{T,C<:AbstractDataCodec}
    offset::Int64          # byte offset into the (decompressed) source
    nbytes::Int64          # stored size; differs from prod(dims)*sizeof(T) when compressed
    dims::Dims{2}          # (fast axis, slow axis) — see §7
    byteorder::ByteOrder
    codec::C               # RawBlob(), ByteOffset(), PCK(), TY1(), AGIBitfield(), ZlibBlob()
    transform::Orientation # identity / flipud / fliplr / transpose, per format convention
end

struct FrameSpec{L}
    header::Header
    layout::L              # ::BinaryLayout{T} for blob formats, ::Nothing for tier-2 formats
end
```

`T` and the codec are type parameters, so once the layout is built the decode path is fully
specialised and native-endian raw blobs compile to a `reinterpret`/`copyto!`.

```julia
# ---- The open file handle --------------------------------------------------
mutable struct ImageFile{F<:ImageFormat, S<:AbstractSource, X, T, N} <: AbstractVector{ImageFrame}
    format::F
    source::S
    path::Union{Nothing,String}
    fileheader::Header       # file-level metadata (EDF "general block", NeXus entry attrs)
    frames::Vector{FrameSpec}
    state::X                 # format-private scratch (HDF5 handle, TIFF IFD table, …)
    truncated::Bool          # fabio's `incomplete_file`
end
```

`X` is a type parameter rather than a field of an abstract base, so no format subclasses
anything to keep its own bookkeeping. `ImageFile <: AbstractVector{ImageFrame}` gives
`length(f)`, `f[3]`, `f[2:5]`, `for frame in f` and `collect` for free.

### 4.2 One frame model, not two — dropping `next()`

The docs describe two coexisting APIs and are candid about the older one:

> "for single-frame format (like mar345), `next` will return the image in next file; for
> multi-frame format (like GE), `next` will return the next frame within the same file. For
> formats which are possibly multi-framed like EDF and TIFF, the behaviour can be
> complicated" … "This convenient way to iterate through many files has limitations."

Reproducing that ambiguity in a new library would be a mistake. Fabio.jl exposes only the
composition model the docs themselves moved to:

- **within a file**: `file[i]`, `length(file)`, iteration;
- **across files**: `Fabio.open_series(...)`, indexed and iterated the same way;
- **filename arithmetic**, when that is genuinely what you want, as an explicit utility:
  `Fabio.nextfile(path)`, `Fabio.prevfile(path)`, `Fabio.jumpfile(path, n)`.

The doc's mar2300 example (§16.5) then reads the same whether the format is single- or
multi-frame — which the fabio version does not.

### 4.3 Writing implies coercion

Per Correction 1, the writer path is `coerce` → `translate headers` → `encode` → `emit`, with
`coerce` defaulting to identity. `Fabio.writeimage` and `Fabio.convertimage` share it, so
`convert(frame, EDF())` and `write("x.esperanto", frame)` cannot diverge.

---

## 5. The extension interface — two tiers

### Tier 1 — "header + blob" (most of fabio's formats, including Esperanto)

Implement one method. The core handles opening, decompression, mmap, decoding, byteswapping,
orientation, frame iteration, and error reporting.

```julia
"""
    scan(fmt, src) -> (fileheader::Header, specs::Vector{FrameSpec})

Parse metadata only. Must not read pixel data. Called once per `Fabio.open`.
"""
function Fabio.scan(::EDF, src::AbstractSource)
    fileheader, specs, pos = Header(), FrameSpec[], 0
    while pos < filesize(src)
        h, blobstart, blobsize = read_edf_block(src, pos)
        T     = EDF_DATA_TYPES[h["DataType"]]            # "UnsignedShort" -> UInt16
        dims  = (getheader(h, "Dim_1", Int), getheader(h, "Dim_2", Int))
        bo    = startswith(h["ByteOrder"], "Low") ? LittleEndian() : BigEndian()
        codec = get(h, "Compression", "None") == "None" ? RawBlob() : ZlibBlob()
        push!(specs, FrameSpec(h, BinaryLayout{T,typeof(codec)}(
            blobstart, blobsize, dims, bo, codec, Identity())))
        pos = blobstart + blobsize
    end
    return fileheader, specs
end
```

Registration is one declarative call:

```julia
Fabio.register!(EDF();
    name = :edf, description = "ESRF Data Format",
    extensions = ["edf", "cor"],
    magic = [Magic(b"{\r\nEDF", 0), Magic(b"{\n", 0)],
    priority = 0, writer = true)
```

### Tier 2 — full control (TIFF, HDF5, JPEG)

Add one more method; the format takes over pixel reading but still gets detection,
compression, series handling, and the public API for free.

```julia
Fabio.openstate(::NexusLike{:eiger}, src) -> X            # optional, default `nothing`
Fabio.readframe(file::ImageFile{<:NexusLike}, i::Int) -> ImageFrame
Fabio.closestate(::NexusLike, state)                      # optional
```

### Optional methods (sensible defaults everywhere)

```julia
Fabio.needs_random_access(::ImageFormat) = true   # false ⇒ can stream a .gz without buffering
Fabio.refine(::TIFFLike, head, path, src)         # disambiguate a format family (§6)
Fabio.coerce(::ImageFormat, A)                    # §4.3, write/convert numeric adaptation
Fabio.writeformat(::EDF, path, arrays, headers)   # opt-in writer (§4.3)
Fabio.layoutkeys(::EDF)                           # keys describing how a format stores
Fabio.normalise(::EDF, h::Header)                 # opt-in common-metadata mapping (§11)
```

**An out-of-tree format package is exactly this**: `using Fabio`, define
`struct MyDetector <: Fabio.ImageFormat end`, one `scan` method, `Fabio.register!` in
`__init__`. No fork, no PR, no monkey-patching — the Julia answer to the docs' "add your new
module as an import into fabio.fabioformats" step in `templateimage.py`.

---

## 6. Format detection

fabio's magic table is a flat list with entries like `"eiger/lima/sparse/hdf5/lambda"` and
`"marccd/tif"` — strings that then get special-cased inside `_do_magic`. Fabio.jl makes that
a first-class two-stage mechanism.

```julia
struct Magic
    pattern::Vector{UInt8}
    offset::Int
end

struct FormatEntry
    format::ImageFormat
    name::Symbol
    description::String
    extensions::Vector{String}
    magics::Vector{Magic}
    priority::Int          # higher wins; out-of-tree packages can outrank builtins
    reader::Bool
    writer::Bool
end
```

Resolution order in `detectformat(head, path)`:

1. Explicit `format=` keyword — skip everything else.
2. Magic match, candidates ordered by `(priority, length(pattern))` descending — longest,
   most specific pattern wins. This is what makes `\x49\x49\x2a\x00\x82\x00` (Pilatus) beat
   generic little-endian TIFF `\x49\x49\x2a\x00`, without fabio's ordering-by-convention.
3. **`refine(fmt, head, path, src)`** — the format family inspects further and may return a
   more specific format. `NexusLike{:unknown}` reads the `creator` attribute and returns
   `{:lima}` / `{:eiger}` / `{:lambda}` / `{:sparse}`; `TIFFLike{:plain}` checks for `.mccd`
   and returns `{:marccd}`. Expensive probing lives here, not in the magic table.
4. Extension lookup, if no magic matched. (The docs are explicit that this is the fallback:
   "FabIO tries to deduce the actual format from the file itself and only uses extensions as
   a fallback if that fails.")
5. Last resort: try each candidate's `scan` in priority order, under `Fabio.openimage(path; trial=true)`.

`Magic` carries an offset, so formats whose signature is not at byte 0 need no hacks.

---

## 7. Memory layout and axis order — a deliberate divergence

numpy is row-major, so fabio's `data.shape == (dim2, dim1) == (slow, fast)` and a raw blob
maps straight onto memory. Julia is column-major. The choice is real:

| Option | `size(frame)` | Consequence |
|---|---|---|
| **A. fast axis first (recommended)** | `(dim1, dim2)` = `(fast, slow)` | Stored bytes map **directly** onto a Julia array: zero-copy `reinterpret`, mmap works, no transpose. Index as `frame[x, y]`. |
| B. match numpy | `(dim2, dim1)` = `(slow, fast)` | Every read pays a `permutedims` copy; mmap becomes useless; matches fabio's `.shape` when porting Python. |

**Recommendation: A.** The Esperanto codec (§15) is independent evidence: AGI bitfield decodes
**row by row** and finishes with a cumulative sum along each row. Under option A a detector row
is `A[:, y]` — contiguous in Julia's column-major memory, so both the row decode and its
`cumsum!` run over contiguous cache lines. Under option B each row is a strided slice. The
same argument holds for CBF byte-offset and mar345 PCK, which are also row-oriented.

The cost is one clearly-documented gotcha, mitigated with adapters:

```julia
Fabio.rowmajor(frame)   # PermutedDimsArray view, numpy-order (slow, fast) — no copy
Fabio.imageview(frame)  # (row, col), top-left origin, for Images.jl / display conventions
```

Per-format origin conventions (some detectors store bottom-up) are handled declaratively by
`BinaryLayout.transform`, applied once in the core, and recorded so a writer can invert it.

---

## 8. Type stability

The element type is a *runtime* value from the header, so `read` cannot be type-stable at its
boundary. That is fine if the instability is confined to one call, so the design puts a
**function barrier at open time**:

- `Fabio.openimage(path)` scans headers, learns `T`, and constructs `ImageFile{F,S,X,T,N}` — one
  dynamic dispatch, once per file.
- Everything after is inferred: `file[i] :: ImageFrame{T,2,Array{T,2}}`, and user loops over
  frames are fully typed.
- Heterogeneous multi-frame files (legal in EDF) get `T = Any`; those users opt into
  `Fabio.readimage(path, Float32)`.

```julia
Fabio.eltype(path)                # header-only, no pixel read
Fabio.readimage(path, Float32)         # always Array{Float32,2}, stable
Fabio.readframe!(dest::Array, file, i) # zero-allocation read into a preallocated buffer
```

`decode` dispatch is closed over a `Union` of the ~10 supported element types, so the dynamic
call resolves to a small union-split rather than full dynamic dispatch per frame.

The mmap fast path matters: for an uncompressed file with a `RawBlob` layout in native byte
order, `readframe` returns `reshape(reinterpret(T, mmap_view), dims)` — **zero copy, zero
allocation**, a capability fabio does not have.

---

## 9. Compression — two independent axes

fabio conflates these; separating them removes a class of bugs.

**Axis 1: container compression** (the whole file is gzipped). Entirely in `io/source.jl`,
invisible to formats:

```julia
opensource(path) =
    endswith(path, ".gz")  ? decompressed(path, GzipDecompressor)  :
    endswith(path, ".bz2") ? decompressed(path, Bzip2Decompressor) :
    endswith(path, ".xz")  ? decompressed(path, XzDecompressor)    :
    endswith(path, ".zst") ? decompressed(path, ZstdDecompressor)  :
    MmapSource(path)
```

fabio's `_need_a_seek_to_read` / `_need_a_real_file` flags — its workaround for non-seekable
decompression streams, including a `tempfile` dance in `_compressed_stream` — collapse to one
trait plus one source type:

```julia
Fabio.needs_random_access(::ImageFormat) = true    # default: safe
```

If `true` and the file is compressed, the source is a `BufferSource`: decompressed once into
memory, then randomly addressable. If `false`, a `StreamSource` streams it. No temp files, no
platform branches.

```julia
abstract type AbstractSource end
struct MmapSource   <: AbstractSource end   # plain file, Mmap.mmap, zero-copy views
struct BufferSource <: AbstractSource end   # fully in memory (decompressed or stream input)
struct StreamSource <: AbstractSource end   # forward-only, for large streamable files

bytes(src, offset, n)      # zero-copy view where possible
pread!(dest, src, offset)  # copying read
Base.filesize(src); israndomaccess(src); materialise(src)
```

**Axis 2: data-blob codecs** (compression *inside* an otherwise-plain file):

```julia
abstract type AbstractDataCodec end
struct RawBlob     <: AbstractDataCodec end
struct ByteOffset  <: AbstractDataCodec end   # CBF/CIF binary, the pyFAI workhorse
struct PCK         <: AbstractDataCodec end   # mar345
struct TY1         <: AbstractDataCodec end
struct AGIBitfield <: AbstractDataCodec end   # Esperanto — see §15
struct PackBits    <: AbstractDataCodec end   # TIFF
struct ZlibBlob    <: AbstractDataCodec end   # EDF Compression=Zlib/Gzip

decode(codec, raw::AbstractVector{UInt8}, ::Type{T}, dims) -> Array{T,2}
encode(codec, A::AbstractArray{T,2})                       -> Vector{UInt8}
```

Pure functions over byte buffers: trivially unit-testable, independently optimisable.
`ByteOffset`, `PCK` and `AGIBitfield` need hand-tuned loops. fabio ships Cython for
byte-offset and mar345, but — as §15 shows — **not** for AGI bitfield decompression, which is
pure Python and correspondingly slow. `@inbounds`/`@simd` Julia should match the Cython where
it exists and beat it comfortably where it does not, while staying pure Julia with **no build
step and no compiler toolchain on the user's machine** — a concrete packaging advantage over
fabio, whose docs note "This code has to be compiled for each computer architecture."

---

## 10. Public API

```julia
# --- reading -----------------------------------------------------------------
Fabio.openimage(path; format=nothing, mmap=true, strict=true) -> ImageFile   # lazy; close it
Fabio.openimage(f::Function, path; kwargs...)                   # do-block form
Base.close(file)

Fabio.readimage(path)               -> ImageFrame  # frame 1, file closed on return
Fabio.readimage(path; frame=i)      -> ImageFrame
Fabio.readimage(path, ::Type{T})    -> ImageFrame{T}
Fabio.readframe!(dest, file, i)     -> dest

Fabio.readheader(path)      -> Header              # metadata only, no pixel read
Fabio.readheaders(path)     -> Vector{Header}      # one per frame

file[i]; length(file); for frame in file … end     # AbstractVector interface
Fabio.framestack(file)      -> Array{T,3}          # all frames as a cube

# --- writing -----------------------------------------------------------------
Fabio.writeimage(path, frame; format=nothing)           # format from extension if omitted
Fabio.writeimage(path, frames::AbstractVector{<:ImageFrame})
Fabio.convertimage(frame, EDF())                        # coerce + header translation (§4.3)

# --- series ------------------------------------------------------------------
Fabio.open_series(paths)                           # or first = "img_0001.edf"
Fabio.nextfile(path); Fabio.prevfile(path); Fabio.jumpfile(path, n)

# --- introspection -----------------------------------------------------------
Fabio.formats()                                    # the table the docs hand-maintain (§2)
Fabio.info(path)                                   # human-readable dump
```

The path-based entry points are named `openimage`/`readimage` rather than `open`/`read`.
Adding a method to `Base.open(::AbstractString)` would be type piracy — Base already owns that
signature and keyword arguments do not participate in dispatch — and shadowing `open` inside
the module is worse. `openimage` also matches FabIO's own internal name. Everything that
dispatches on this package's own types (`close`, `length`, `getindex`, iteration) extends
`Base` normally.

Optional **FileIO.jl** registration so `load("img.edf")` works ecosystem-wide — ~30 lines in a
package extension, no hard dependency.

---

## 11. Optional: normalised metadata

fabio deliberately does not unify header semantics across formats, and Fabio.jl should not
*by default*. A thin, clearly optional layer is cheap:

```julia
struct ImageMetadata
    exposure_time::Union{Nothing,Float64}
    wavelength::Union{Nothing,Float64}
    detector_distance::Union{Nothing,Float64}
    beam_center::Union{Nothing,NTuple{2,Float64}}
    pixel_size::Union{Nothing,NTuple{2,Float64}}
    timestamp::Union{Nothing,DateTime}
end

Fabio.normalise(frame) -> ImageMetadata
```

Esperanto is a good demonstration: its header carries `dexposuretimeinsec`, `dalpha1`
(wavelength), `ddistanceinmm`, `dxorigininpix`/`dyorigininpix`, `drealpixelsizex/y` — all six
fields, already numerically decoded. The raw `Header` always remains the source of truth.

---

## 12. Package structure

```
Fabio.jl/
├── Project.toml
├── src/
│   ├── Fabio.jl               module, includes, exports, __init__ registration
│   ├── types.jl               ImageFormat, ImageFrame, Header, ByteOrder, errors
│   ├── header.jl              Header + typed accessors
│   ├── registry.jl            FormatEntry, register!, formats()
│   ├── detect.jl              magic table, refine dispatch, extension map
│   ├── io/source.jl           MmapSource / BufferSource / StreamSource
│   ├── io/compress.jl         gz / bz2 / xz / zst
│   ├── blob.jl                BinaryLayout → Array (decode, bswap, orient, mmap path)
│   ├── codecs/                raw, byteoffset, pck, ty1, agi, packbits, zlibblob
│   ├── formats/               edf, esperanto, cbf, mar345, bruker, adsc, oxd, pnm, numpy, …
│   ├── series.jl              FileSeries, filename arithmetic
│   ├── convert.jl             coerce + cross-format header translation
│   ├── testsuite.jl           Fabio.test_format(...) — conformance tests for ANY format
│   └── api.jl                 public surface
├── ext/
│   ├── FabioHDF5Ext.jl        Eiger / Lima / Lambda / sparse / generic NeXus
│   ├── FabioTiffExt.jl        TIFF family (plain, Pilatus, MarCCD, HiPiC)
│   ├── FabioJpegExt.jl        JPEG / JPEG2000
│   └── FabioFileIOExt.jl      FileIO.jl registration
├── test/  (runtests.jl, usecases.jl ← §16, Artifacts.toml, codec unit tests)
└── docs/
```

```toml
name = "Fabio"

[deps]                       # deliberately light
OrderedCollections = "…"
CodecZlib          = "…"     # .gz is ubiquitous — hard dep
CodecBzip2         = "…"     # .bz2 likewise (fabio supports it)
TranscodingStreams = "…"
Mmap = "…"; Dates = "…"      # stdlib
PrecompileTools    = "…"     # latency

[weakdeps]
HDF5 = "…"; TiffImages = "…"; JpegTurbo = "…"; CodecXz = "…"; CodecZstd = "…"; FileIO = "…"

[extensions]
FabioHDF5Ext = "HDF5"; FabioTiffExt = "TiffImages"
FabioJpegExt = "JpegTurbo"; FabioFileIOExt = "FileIO"
```

Package extensions (Julia ≥1.9) keep the core installable in seconds; HDF5 support appears the
moment the user does `using HDF5`. When a format needs an unloaded extension, detection raises
an actionable error:

```
UnsupportedFormatError: file "scan.h5" is HDF5/Eiger; run `using HDF5` to enable this reader.
```

---

## 13. Errors, robustness, concurrency

```julia
abstract type FabioError <: Exception end
struct UnknownFormatError     <: FabioError end   # nothing matched
struct UnsupportedFormatError <: FabioError end   # recognised, reader not loaded
struct CorruptFileError       <: FabioError end   # header inconsistent with data
struct TruncatedFileError     <: FabioError end   # fabio's `incomplete_file`
```

Truncated files are common with detectors writing live (fabio has explicit handling for
partial gzip blocks in EDF). `Fabio.openimage(path; strict=false)` returns whatever frames scanned
cleanly and sets `file.truncated = true`; the default is strict, so silent data loss is opt-in.

**Concurrency**: an `ImageFile` holds mutable I/O state and is not thread-safe — document it,
make "open per task" cheap. `MmapSource` is the exception: immutable and read-only, so
`readframe` on a memory-mapped file *is* thread-safe, making the bulk-conversion use case
(§16.8) trivially parallel with `Threads.@threads`.

---

## 14. Testing and test data

- **`Fabio.test_format(fmt, path; mean=…, min=…, max=…, sum=…)`** — public, so out-of-tree
  format packages inherit the whole conformance battery. Highest-leverage extensibility feature.
- **`test/usecases.jl`** — §16 executed verbatim as the acceptance suite. If the documented
  fabio examples all have working Julia counterparts, the port is functionally complete.
- **Reference values ported from fabio's own test suite** (min/max/mean/stddev per file).
- **Round-trip tests** per writer; **codec unit tests** on synthetic buffers; **`@inferred`**
  guarding §8's type-stability contract; **Aqua.jl** + **JET.jl** in CI.

### Data sources

| Source | Contents | Exercises |
|---|---|---|
| **Zenodo 2546760** (CC-BY, DOI 10.5281/zenodo.2546760) | 160 × `200mMmgso4_%03d.mar2300`, ~2.85 MB each, 452 MB total | mar345 reader + **PCK codec** + the doc's file-series example (§16.5). Per-file URLs (`/records/2546760/files/NAME?download=1`) mean CI pulls **3 files, ~9 MB**, not 452 MB — set up as separate lazy artifacts. |
| **fabio's own test-image releases** | one file per format | per-format coverage, as lazy `Artifacts` |
| **Local: `01_enstatite_data`** | 140 × `enst_s1_1_*.esperanto`, 2048², AGI_BITFIELD | AGI codec, series iteration, parallel-decode benchmark. Likely not redistributable → gate behind `FABIO_JL_LOCAL_TESTDATA=<dir>`, skipped when unset. |

---

## 15. Worked format: Esperanto (verified against your files)

I parsed `enst_s1_1_1.esperanto` and `enst_s1_1_100.esperanto` directly, independently of
fabio, to confirm the structure the design has to express.

### On-disk structure — confirmed

```
byte 0                    ASCII header: 25 lines × 256 bytes = 6400 bytes
                          each line CRLF-terminated; final line ends 0x0D 0x1A
  line 0  ESPERANTO FORMAT   1 CONSISTING OF   25 LINES OF   256 BYTES EACH
  line 1  IMAGE 2048 2048 1 1 "AGI_BITFIELD"        ← lnx lny lbx lby spixelformat
  …       TIME / PIXELSIZE / WAVELENGTH / GONIOMODEL_1 / STARTANGLESINDEG / …
byte 6400                 uint32 LE  data_size
byte 6404                 compressed row stream, data_size bytes
byte 6404+data_size       row-start index table: lny × uint32 LE
```

Verified arithmetic on both files — e.g. `enst_s1_1_1`: file 3 180 288 B = 6 400 header
+ 4 + 3 165 692 blob + 8 192 index. 2048×2048 `Int32` = 16 777 216 B raw, so **5.3×
compression**. The header's line count and line width are read from line 0 rather than
assumed, matching fabio.

### Reference values — the first test fixture

Read back with fabio itself, for `enst_s1_1_1.esperanto`:

| quantity | value |
|---|---|
| shape / dtype | `(2048, 2048)` / `int32` |
| min / max | `-4957` / `58167` |
| mean / std | `73.173096` / `147.530006` |
| sum | `306910208` |
| first 5 pixels of row 0 | `[0, 6, -1, 6, 3]` |

Note the **negative minimum**: `Int32` here is genuinely signed data, not a convention. A
reader that assumed unsigned (a natural guess for a photon-counting detector) would be
silently wrong — which is why `test_format` checks `min` and not just `max`/`mean`.

### Performance baseline — and an easy win

fabio took **0.79 s** to decode one 2048² frame here. That is because
`fabio/ext/_agi_bitfield.pyx` exports only `get_fieldsize`, `compress_row` and `compress` —
**AGI bitfield *de*compression has no Cython accelerator at all**. `decompress_row` is pure
Python, walking a `BytesIO` byte by byte and accumulating Python `list`s, one row at a time.

A straightforward Julia implementation over a `Vector{UInt8}` with `@inbounds` should be
roughly an order of magnitude faster before any threading, and the row index table below
multiplies that by the core count. On your 140-file set that is the difference between ~110 s
and a couple of seconds for a full pass.

### Why this format validates the architecture

Esperanto has two on-disk variants. In fabio they are an `if/elif` inside `read` with separate
code paths. Here they are **one `scan` function differing in a single struct field**:

```julia
function Fabio.scan(::Esperanto, src::AbstractSource)
    h, nlines = read_esperanto_header(src)              # 256-byte lines, key-prefix decoding
    dims = (getheader(h, "lnx", Int), getheader(h, "lny", Int))   # (fast, slow)
    off  = nlines * 256
    codec = h["spixelformat"] == "AGI_BITFIELD" ?
                AGIBitfield(rowindex(src, off, dims[2])) : RawBlob()
    layout = BinaryLayout{Int32,typeof(codec)}(
        off, filesize(src) - off, dims, LittleEndian(), codec, Identity())
    return h, [FrameSpec(h, layout)]
end
```

Everything else — mmap, `.gz` handling, frame iteration, statistics, the `AbstractArray`
interface — comes from the core untouched.

### A capability fabio leaves unused

fabio's `agi_bitfield.decompress` reads the row-start index table and then discards it:

> `# read data components (row indices are ignored)`

It decodes all `lny` rows strictly sequentially. But that table is exactly a **random-access
index into the compressed stream**. Keeping it (as `AGIBitfield(rowindex)` above) buys three
things fabio cannot do:

1. **Parallel decode** — `Threads.@threads for y in 1:lny` decoding into disjoint columns of
   the output. Row decode is the dominant cost on a 2048² frame.
2. **ROI reads** — decode only the rows a region of interest touches, instead of the frame.
3. **Bounds validation** before decoding, turning silent corruption into `CorruptFileError`.

The codec's trailing `cumsum` along each row also confirms §7's axis choice: with fast-axis
first, a detector row is a contiguous Julia column, so decode and `cumsum!` both run over
contiguous memory.

---

## 16. Use cases — every documented fabio example, in Julia

These are the acceptance criteria; they become `test/usecases.jl`.

### 16.1 Open, inspect header, mean intensity

```python
import fabio
image = fabio.open('image.tif')
print(image.header)
print(image.data.mean())
image.close()
```
```julia
using Fabio, Statistics
Fabio.openimage("image.tif") do file
    frame = file[1]
    display(header(frame))
    println(mean(frame))          # ImageFrame <: AbstractArray, so `mean` just works
end
```

### 16.2 Normalise to a header value and save

```python
img = fabio.open('exampleimage0001.edf')
srcur = float(img.header['ESRFCurrent'])
img.data *= 200.0/srcur
img.write('normed_0001.edf')
```
```julia
frame = Fabio.readimage("exampleimage0001.edf")
srcur = getheader(header(frame), "ESRFCurrent", Float64)
Fabio.writeimage("normed_0001.edf", frame .* (200.0 / srcur))
```
Note this is a case where `coerce` (§4.3) earns its keep: `frame .* Float64` produces a
`Float64` array, and the EDF writer records `DataType = DoubleValue` rather than silently
truncating — while an Esperanto writer would round to `Int32` and say so.

### 16.3 Convert TIFF to EDF

```python
image = fabio.open("my.tiff")
image.convert("edf").save("my.edf")
```
```julia
Fabio.writeimage("my.edf", Fabio.convertimage(Fabio.readimage("my.tiff"), EDF()))
```

### 16.4 Display

```python
from matplotlib import pyplot
pyplot.imshow(img.data); pyplot.show()
```
```julia
using GLMakie
# Makie's first array axis is x, so the stored (fast, slow) order needs no permutation;
# yreversed puts the origin top-left, where matplotlib's imshow has it.
heatmap(frame; axis = (yreversed = true, aspect = DataAspect()))
```

### 16.5 File series, the doc's mar2300 example (Zenodo 2546760)

```python
im1 = fabio.open("200mMmgso4_001.mar2300")
print(im1.data[1024,1024])
im2 = im1.next()
print(im2.filename)          # 200mMmgso4_002.mar2300
im5 = im1.getframe(5)        # jumps to file number 5
```
```julia
series = Fabio.open_series(first = "200mMmgso4_001.mar2300")
println(series[1][1024, 1024])
println(series[2].source)        # …_002.mar2300
frame5 = series[5]               # unambiguous: 5th frame of the series (§4.2)
```

### 16.6 Random access across a series

```python
with fabio.open_series(first_filename="foobar_0000.edf") as series:
    frame1, frame100, frame19 = series.get_frame(1), series.get_frame(100), series.get_frame(19)
```
```julia
Fabio.open_series(first = "foobar_0000.edf") do series
    frame1, frame100, frame19 = series[1], series[100], series[19]
end
```

### 16.7 Sequential access with full frame provenance

```python
for frame in series.frames():
    frame.data; frame.header; frame.index; frame.file_index
    frame.file_container.filename
```
```julia
for frame in series
    frame                      # the data (it *is* an AbstractArray)
    header(frame)
    frame.seriesindex          # index within the series
    frame.fileindex            # index within its source file
    frame.source               # path of the source file
end
```
The docs note sequential access is ~2× faster than random for large EDF series; the design
supports that with `needs_random_access(::EDF) = false` where the scan permits streaming.

### 16.8 Bulk convert a directory, CBF → EDF (tutorial `convert_CBF`)

```python
for onefile in files:
    fabio.open(onefile).convert("edf").save(dst)
```
```julia
files = sort(filter(endswith(".cbf"), readdir(srcdir; join=true)))
mkpath(dstdir)
Threads.@threads for f in files                     # mmap sources are thread-safe (§13)
    dst = joinpath(dstdir, first(splitext(basename(f))) * ".edf")
    Fabio.writeimage(dst, Fabio.convertimage(Fabio.readimage(f), EDF()))
end
```
The tutorial reports ~28 frames/s single-threaded in Python; this is the natural benchmark to
quote in the README, and the loop above is embarrassingly parallel by construction.

### 16.9 Eiger/NeXus HDF5 → per-frame CBF (tutorial `Nexus2cbf`)

```python
images = fabio.open("collect_01_00001_master.h5")
for idx, frame in enumerate(images):
    fabio.cbfimage.cbfimage(header=header, data=frame.data).write("…_%04i.cbf" % idx)
```
```julia
using HDF5                                   # activates FabioHDF5Ext
Fabio.openimage("collect_01_00001_master.h5") do images
    for (i, frame) in enumerate(images)
        Fabio.writeimage(@sprintf("collect_01_00001_%04d.cbf", i),
                    ImageFrame(parent(frame), detectorheader, i, i, nothing); format = CBF())
    end
end
```

### 16.10 HDF5 → multi-frame TIFF, then compare frame statistics (tutorial `convert_tiff`)

```julia
using TiffImages
src = Fabio.openimage("sample_water0000.h5")
Fabio.writeimage("sample_water0000.tiff", collect(src))     # multi-frame writer
dst = Fabio.openimage("sample_water0000.tiff")
for i in 1:length(src)
    a, b = src[i], dst[i]
    @assert a == b                                      # the tutorial's final check
    @printf("%4d  %8d %8d %10.4f %10.4f\n", i, minimum(a), maximum(a), mean(a), std(a))
end
```

### 16.11 Command-line tools

The docs ship five CLI apps. `fabio-convert` is the one that belongs in v1; the others are
domain-specific (`eiger2cbf`, `eiger2crysalis`, `densify_Bragg`) or a GUI (`fabio_viewer`).

```bash
julia -e 'using Fabio; Fabio.main()' -- --output-format edf *.cbf
```
Ship as a `Fabio.main()` entry point plus a `bin/fabio-convert` shim via
PackageCompiler/juliaup app; `--list` prints `Fabio.formats()`. Note `eiger2crysalis` writes
**Esperanto** output — with the Esperanto writer (`coerce` doing the square/multiple-of-4
padding, §4.3) that tool becomes straightforward to port later.

---

## 17. Roadmap

| Phase | Content | Why |
|---|---|---|
| **0** ✅ | Core: types, sources, compression, registry, detection, blob reader, `RawBlob`, `ZlibBlob`. Formats: **EDF**, **Esperanto** (+`AGIBitfield`), `.npy`. **Built and tested** — 168 self-contained tests plus 22 against real Esperanto data. | EDF exercises multi-frame, per-frame headers, endianness, zlib blobs, `.gz`. Esperanto adds a real codec validated against your 140 files. Together they proved tier 1. |
| **1** ✅ | `ByteOffset` + **CBF**; `PCK` + **mar345**; the **TIFF family** (plain, Pilatus, MarCCD) in the core rather than an extension; **ADSC/d\*TREK**, **Bruker 86 and 100**. | Done. TIFF turned out to be mostly tier 1 — see the note below — and multi-strip TIFF is what exercises tier 2. |
| **2** ✅ | **OXD** (TY1, TY5), **GE**, **Netpbm**, **MRC**, **SPE**, **Fit2D** binary and mask, **KCD**, **R-AXIS**, **MPA**, **DM3**, **Xcalibur**. | Done, all tier 1. Xcalibur had no reader in FabIO to port — its `read` is unmodified template boilerplate that raises — so this one is new work rather than a translation. |
| **3** ✅ | HDF5 family via ext: **Eiger, Lima, Lambda, sparse, generic NeXus**, incl. `file.h5::/path` URLs. | Done. The weak-dependency design and tier 2 both worked as written; see below. |
| **4** ⬅ in progress | `writeimage` over the per-format writers ✅, `convertimage` + the `coerce`/`layoutkeys` matrix ✅, §16 as `test/usecases.jl` ✅, `FileSeries` + filename arithmetic ✅; FileIO.jl registration, `ImageMetadata` and a `fabio-convert` CLI still to do. | Parity polish. |

**What phase 3 confirmed.** This was the phase the two-tier design existed for, and it needed
no new mechanism. `refine` returning a more specific format — added in phase 2 so SPE could
decline a file — is exactly what resolves the five HDF5 flavours, which FabIO handles with the
magic-table string `"eiger/lima/sparse/hdf5/lambda"` and a branch inside its detection loop.
`openstate`/`closestate`, speculated in §5 with "an HDF5 handle" as the example, holds an HDF5
handle. The weak dependency behaves as §12 describes, error message included.

Three things were better than predicted. The axis choice of §7 pays off a second time and for
a second reason: HDF5.jl reverses a dataset's dimensions when mapping C-order storage into a
column-major language, so a stack arrives as `(fast, slow, nframes)` — already this
package's convention — and the sparse format's peak list, which indexes the C-order raveled
image, is by the same token already a Julia linear index. Neither reader contains a transpose.
Second, `scan` never needed access to the state: it opens the file, enumerates, and closes,
and `openstate` opens it again to read from. Third, the `::` fragment fitted on the *source*
rather than in `scan`'s signature, so the tier-1 contract was untouched.

One correction to §8. It claims that after `openimage` "everything after is inferred:
`file[i] :: ImageFrame{T,2,Array{T,2}}`". That is not true for a tier-2 format, and never was:
a frame descriptor is reached through `ImageFile.frames::Vector{FrameSpec}`, whose parameter
is abstract, so the element type is recovered at run time. The cost is one dispatch per frame
against reading a whole frame, which is why it has not mattered — but the claim is too strong
as written.

**What the first three phases changed about this design.** Two predictions in §3 and §5 were
wrong in interesting ways. TIFF was expected to be the tier-2 exercise; it is not, because a
contiguous image — even a multi-strip one — is still a single `BinaryLayout`, so only genuinely
disjoint strips need `readframe`. "Offset plus codec" describes more formats than this document
predicted. Of the 24 registered formats, only two families read their own pixels: TIFF, and
then only for a genuinely multi-strip image, and HDF5, throughout — the latter because an HDF5
dataset is not bytes at an offset at all. Everything else is tier 1.

Separately, a magic match had to stop being final: SPE has no signature and a header of mostly
zeros, so it collided with GE's blanked-header signature, and `refine` now returns `nothing` to
decline a file and let detection continue.

See [STATUS.md](STATUS.md) for where the work actually stands, the open questions, and how to
run the real-data tests.

Phase 0 was the real design test — roughly two weeks. Everything after is largely mechanical
per-format work, which is the point of the architecture.

---

## 18. Open questions

1. **Axis order** (§7) — the one expensive-to-reverse decision. Recommendation: fast-axis-first,
   with `rowmajor()`/`imageview()` adapters. The Esperanto codec analysis in §15 supports it.
2. **1-based indexing** — Julia says yes; fabio users expect 0. Go 1-based and say so loudly.
   Note `eiger2crysalis` already has an `--offset` flag because CrysalisPro is 1-based, so
   1-based is not alien to this domain.
3. ~~Header value types~~ — **settled** by the docs (§2): store as recorded, typed accessors on top.
4. **`ImageFrame <: AbstractArray`** — recommended yes; it is what makes §16.1–16.10 read as
   naturally as the Python.
5. ~~Name collisions~~ — **settled during implementation**: path-based entry points are
   `openimage` / `readimage` / `writeimage` / `convertimage` / `readframe!` / `framestack`,
   because methods on `Base.open(::AbstractString)` and `Base.read(::AbstractString)` would be
   piracy. `writeimage` is the same decision one step further on: `Base.write(filename, x)`
   already writes a plain array as raw bytes, so a method on it for `AbstractMatrix` would
   change what existing code does rather than add to it. Nothing exported shadows `Base`.

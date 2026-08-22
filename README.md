# Fabio.jl

**Warning** - This Julia library is under development and has not yet been
thoroughly tested. Many tests on synthetic and real data have been done, as
well as comparison with the `fabio` Python library. However, if you use this
library you are advised to make a through validation check on your data (please
raise an issue, if you find a problem).

## Introduction

Reading of 2D detector images and their metadata, after the Python
[FabIO](https://github.com/silx-kit/fabio) library. Give it a filename: it works out the
format, handles compression, and hands back the pixels as a Julia array of the type actually
stored in the file, alongside the header.

Readers exist for Bruker (86 and 100), CBF, d\*TREK/ADSC, DM3, EDF, Esperanto, Fit2D (binary
and mask), GE, HDF5/NeXus (Eiger, LImA, Lambda and sparsify-Bragg), KCD, mar345, MPA, MRC,
Netpbm, OXD, R-AXIS, SPE, TIFF (plain, Pilatus and MarCCD), Xcalibur and NumPy. Fifteen of
them can also be written. See [DESIGN.md](DESIGN.md) for the architecture and the format
roadmap, and [STATUS.md](STATUS.md) for where the work currently stands.

```julia
using Fabio, Statistics

frame = Fabio.readimage("image.edf")
mean(frame)                              # an ImageFrame is an AbstractArray
maximum(frame)

hdr = header(frame)                      # a dictionary of the metadata
hdr["Dim_1"]                             # "2048" — as recorded, so a String here
getheader(hdr, "ESRFCurrent", Float64)   # 200.567 — found and converted in one step

Fabio.openimage("series.edf") do file    # multi-frame files are AbstractVectors
    length(file)
    for f in file
        println(f.fileindex, ": ", maximum(f))
    end
end

Fabio.info("scan.esperanto")             # a `fabio_info`-style dump
```

## What is here

| Piece | File |
|---|---|
| Formats: Bruker (86, 100), CBF, DM3, d\*TREK/ADSC, EDF, Esperanto, Fit2D (binary, mask), GE, KCD, mar345, MPA, MRC, Netpbm, OXD, R-AXIS, SPE, TIFF/Pilatus/MarCCD, Xcalibur, NumPy | `src/formats/` |
| HDF5 family: Eiger, LImA, Lambda, sparsify-Bragg, generic NeXus | `ext/FabioHDF5Ext.jl`, `ext/hdf5/` |
| Writing, conversion, series, normalised metadata | `src/write.jl`, `src/series.jl`, `src/metadata.jl` |
| FileIO.jl registration | `ext/FabioFileIOExt.jl` |
| Codecs: raw, zlib blob, AGI bitfield, CBF byte-offset, mar345 PCK, Bruker overflow tables, Netpbm ASCII and packed bits, Fit2D chunked and bit-mask, R-AXIS photomultiplier, KCD readout summing, MPA ASCII, OXD TY1 and TY5 | `src/codecs.jl`, `src/agi.jl`, `src/byteoffset.jl`, `src/pck.jl`, `src/formats/` |
| Byte sources: mmap, in-memory, `.gz` | `src/source.jl` |
| Registry and detection | `src/registry.jl`, `src/detect.jl` |
| Blob decoding, byte order, orientation | `src/blob.jl` |
| Public API | `src/api.jl`, `src/file.jl` |

## Axis order

`size(frame) == (fast, slow)` — the fast-varying detector axis comes first, the reverse of
numpy's `.shape` as reported by FabIO. This is what lets stored bytes map onto Julia's
column-major memory with no permutation, which is what makes memory-mapped, zero-copy frames
possible at all. `Fabio.rowmajor(frame)` and `Fabio.imageview(frame)` give free views in the
numpy and display conventions.

Frame indices are 1-based, like everything else in Julia. FabIO counts from 0.

## Headers

A `Header` is an `AbstractDict{String,Any}`, so it indexes, iterates and `haskey`s like any
dictionary:

```julia
hdr = header(frame)
hdr["Dim_1"]                 # "2048"
haskey(hdr, "ByteOrder")
for (k, v) in hdr            # insertion order, as recorded in the file
    println(k, " = ", v)
end
```

Values come back **exactly as the file stored them**, which is FabIO's contract too: what the
reader interprets, it interprets into the frame's shape and type, and everything else is left
alone. For the many formats with a text header, that means the values are `String`s.

That is what `getheader` is for:

```julia
getheader(hdr, "ESRFCurrent", Float64)        # 200.567
getheader(hdr, "ESRFCurrent", Float64, 0.0)   # ... or a default if it is missing
```

It is fair to ask why that is not just `Float64(hdr["ESRFCurrent"])`. Because that does not
work — the stored value is a string, and there is no such conversion:

```julia
julia> hdr["ESRFCurrent"]
"200.567"

julia> Float64(hdr["ESRFCurrent"])
ERROR: MethodError: no method matching Float64(::String)
```

`parse(Float64, hdr["ESRFCurrent"])` does work, and for a single known EDF key it is a perfectly
good thing to write. `getheader` earns its place when you are not writing against one known
key in one known format:

- **It does not care whether the value is text or already a number.** Formats with a binary
  header decode fields into real Julia numbers, and `parse` then fails — `parse(Float64, 1.5f0)`
  is a `MethodError`. `getheader` returns `1.5` either way, so code that reads an exposure time
  works across formats rather than for one of them.
- **The lookup is case-insensitive.** Writers disagree about capitalisation within a single
  format, so `hdr["esrfcurrent"]` is a `KeyError` where `getheader(hdr, "esrfcurrent", Float64)`
  is not.
- **A missing or malformed key is a `CorruptFileError` naming the key**, rather than a `KeyError`
  or an `ArgumentError` from inside `parse`; and the four-argument form supplies a default
  instead of throwing.

Neither is preferred. Use `hdr[key]` to see what the file says, and `getheader` when you want a
number out of it.

## Normalised metadata

Six quantities recur across almost every detector format, under a different name and in a
different unit each time. `Fabio.normalise` is a thin, optional layer over the raw header for
exactly those:

```julia
m = Fabio.normalise(Fabio.readimage("scan.esperanto"))

m.exposure_time        # 1.0        seconds
m.wavelength           # 2.9e-11    metres — 1e10 * this is Ångström
m.detector_distance    # 0.4        metres
m.beam_center          # (1024.0, 0.0)      pixels, (fast, slow)
m.pixel_size           # (0.0002, 0.0002)   metres
m.timestamp            # a DateTime, or nothing
```

**Lengths are metres**, so these numbers deliberately do not match the raw header — Esperanto
records millimetres, Bruker centimetres, KCD micrometres, and wavelengths are almost always in
Ångström. Metres throughout is pyFAI's convention, and pyFAI is what most often consumes this
data. The raw `Header` is untouched and remains the source of truth.

Implemented for Esperanto, MarCCD, Pilatus, CBF, d\*TREK/ADSC, Bruker and KCD. Any other
format returns an all-`nothing` result rather than an error, and adding one is a single method:

```julia
Fabio.normalise(::MyDetector, h::Fabio.Header) =
    Fabio.ImageMetadata(exposure_time = getheader(h, "EXPOSURE", Float64, 0.0))
```

FabIO has no equivalent — it deliberately leaves header semantics alone, and so does this
package by default; nothing above is consulted unless you ask for it.

## HDF5

The HDF5 readers arrive with the library:

```julia
using Fabio, HDF5                        # HDF5 is a weak dependency

Fabio.readimage("eiger_master.h5")       # Eiger, LImA, Lambda and sparsify-Bragg
Fabio.readimage("scan.h5::/entry/data")  # or name the dataset, FabIO's "::" syntax
```

Without `using HDF5` such a file is still *recognised* — it just cannot be read, and says so:

```
UnsupportedFormatError: file "scan.h5" is HDF5; run `using HDF5` to enable this reader
```

The `::` separator is optional here, where FabIO requires it. A file that names its data
through the NeXus `default`/`signal` attributes, or that contains exactly one image dataset,
is read without being told where to look; when the choice is genuinely ambiguous the error
lists every candidate.

Real detector files are usually written with a plugin compression filter. Those need the
matching Julia package — `import H5Zbitshuffle` for Eiger's bitshuffle-LZ4 — and until it is
loaded a read fails naming both the filter and the package.

An HDF5 dataset is not a byte range, which is what makes this family the one that genuinely
needs the second extension tier: it reads its own pixels rather than describing a
`BinaryLayout`. It maps onto the axis order here exactly, though — HDF5 stores C-order, and
HDF5.jl reverses the dimensions when mapping into a column-major language, so a stack stored
as `(nframes, slow, fast)` arrives as `(fast, slow, nframes)` with no permutation at all.

## Writing files

Fifteen formats have a writer. They take a path and an array, and optionally a `Header`:

```julia
using Fabio: writeedf, writecbf, writetiff, writenpy

A = rand(UInt16, 2048, 2048)                 # (fast, slow), as everywhere here

writeedf("out.edf", A)                       # or writeedf(path, A, header)
writecbf("out.cbf", A, header(frame))        # byte-offset compressed
writenpy("out.npy", A)                       # numpy reads it with numpy.load
writetiff("out.tif", A; description = "…")   # the tag a Pilatus header lives in
```

Some take several frames, writing a multi-frame file:

```julia
using Fabio: writemrc, writespe, writege
writemrc("stack.mrc", [frame1, frame2, frame3])
```

The full list, all in `src/formats/`: `writebruker`, `writecbf`, `writedtrek`, `writeedf`,
`writefit2d`, `writefit2dmask`, `writege`, `writekcd`, `writemarccd`, `writempa`, `writemrc`,
`writenpy`, `writepnm`, `writespe`, `writetiff`. None is exported, so reach them as
`Fabio.writeedf` or import them by name.

**Be aware of what these are.** Most were written to give the reader tests a fixture that needs
nothing downloaded, and their docstrings say so — "minimal single-frame EDF writer: enough to
round-trip data". They write a correct file of the kind the matching reader expects, but they
do not cover every option of every format. Only MarCCD and Fit2D mask are declared writers in
the registry (`Fabio.formats()`), and MarCCD is the one whose output has been read back by
FabIO to confirm it. A round trip through this package proves only that its reader and writer
agree with each other.

The unified writing API that `DESIGN.md` specifies — `Fabio.write(path, frame)` picking the
format from the extension, `Fabio.convert(frame, EDF())`, and the `coerce` step that adapts an
array to what a format can physically store — is Phase 4 and not yet built. `coerce` itself
exists and is used: writing a Fit2D mask reduces any non-zero pixel to a bit, and Esperanto
pads to a square whose side is a multiple of four.

## FileIO.jl

`using FileIO` registers this package's formats, so `load` and `save` work on them wherever
FileIO is the common currency:

```julia
using Fabio, FileIO

frame = load("scan.cbf")     # an ImageFrame — an AbstractArray carrying its header
save("out.edf", frame)
```

Twenty formats are registered, generated from `Fabio.formats()` so the two cannot drift apart.
The four FileIO already serves through other packages — `.tif`, `.npy`, `.h5` and the netpbm
family — are deliberately left alone: someone loading those through FileIO wants the
ecosystem's answer, not this one. They stay readable here through `Fabio.readimage`.

Detection stays this package's own. FileIO picks a format from a flat table of magic bytes and
extensions; Fabio then ignores that choice and detects the format itself, because its two-stage
scheme knows things the flat table cannot express — three different detector formats share the
`.img` extension, for one.

## Command line

A converter, after FabIO's `fabio-convert`:

```bash
bin/fabio-convert --output-format edf *.cbf
bin/fabio-convert --list                        # the format table
bin/fabio-convert -F mrc -o stacks/ --force *.spe
```

The shim is a one-line wrapper around the same entry point, so it works from Julia too:

```julia
exit(Fabio.main(["--output-format", "edf", "scan.cbf"]))
```

Options and exit codes follow `fabio-convert` — 0 success, 1 a conversion failed, 2 bad
arguments — so a script written against it behaves the same here. `--force`, `--no-clobber`,
`--update` and `--dry-run` all mean what they do in `cp`. Multi-frame files keep every frame,
and each conversion goes through `convertimage`, so headers are translated rather than copied.

## Adding a format

Most formats are "a header, then a typed binary blob". Those need one method — parse the
header, return a `BinaryLayout` — and the core does opening, decompression, memory mapping,
decoding, byte-order correction, orientation, frame iteration and error reporting:

```julia
struct MyDetector <: Fabio.ImageFormat end

function Fabio.scan(::MyDetector, src::Fabio.AbstractSource)
    h = parse_my_header(src)
    layout = Fabio.BinaryLayout{UInt32}(offset, nbytes, (fast, slow);
                                        byteorder = Fabio.BigEndian())
    return Fabio.Header(), [Fabio.FrameSpec(h, layout)]
end

Fabio.register!(MyDetector(); name = :mydetector, extensions = ["mdt"],
                magic = [Fabio.Magic("MYDET")])
```

That works from another package just as well as from inside this one — no fork required.

A format whose pixels are not one contiguous encoded blob overrides `Fabio.readframe` instead.
TIFF uses both routes in one reader: a single-strip image is an ordinary layout, while a
multi-strip one is gathered by hand, falling back to `Fabio.readframe_layout` for the frames
that do not need it.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite is self-contained: it writes its own fixtures rather than downloading anything. Real
detector data is opt-in, since it is generally not redistributable:

```bash
FABIO_JL_LOCAL_TESTDATA=/path/to/esperanto/files \
FABIO_JL_MAR345_TESTDATA=/path/to/mar2300/files \
FABIO_JL_PILATUS_TESTDATA=/path/to/pilatus/tiffs \
FABIO_JL_MARCCD_TESTDATA=/path/to/mccd/files \
FABIO_JL_SFRM_TESTDATA=/path/to/sfrm/files \
FABIO_JL_ADSC_TESTDATA=/path/to/adsc/img/files \
FABIO_JL_MRC_TESTDATA=/path/to/mrc/files \
FABIO_JL_HEXRD_EXAMPLES=/path/to/hexrd/examples \
FABIO_JL_KCD_TESTDATA=/path/to/kcd/files \
  julia --project=. -e 'using Pkg; Pkg.test()'
```

Each of those testsets compares against reference values produced by the Python FabIO reading
the same files. Where a whole-frame comparison is made it uses a **position-sensitive
checksum** — the sum of each value times its flat index — as well as the minimum, maximum and
sum, because a transposition or a reordered strip leaves all three aggregates unchanged.

The HDF5 testsets need no extra data: the fixtures are written by the suite with HDF5.jl. The
real-file ones come from `FABIO_JL_HEXRD_EXAMPLES` alongside the GE tests. Comparing pixels in
a real Eiger file additionally needs its compression filter, so those assertions run only when
`H5Zbitshuffle` is installed and are skipped with a note otherwise; everything structural about
the file is checked either way.

The mar345 files are the dataset the FabIO documentation uses for its file-series example,
Zenodo [10.5281/zenodo.2546760](https://doi.org/10.5281/zenodo.2546760).

## Further reading

| | |
|---|---|
| [docs/validation.md](docs/validation.md) | what each reader has been checked against, and how |
| [docs/performance.md](docs/performance.md) | measured against FabIO on the same files |
| [docs/fabio-py-defects.md](docs/fabio-py-defects.md) | defects found in FabIO along the way |
| [DESIGN.md](DESIGN.md) | architecture, and the reasoning behind it |
| [STATUS.md](STATUS.md) | where the work stands, and what is next |

## Licence

MIT — see [LICENSE](LICENSE). Copyright 2026 Graeme Andrew Stewart and Deutsches
Elektronen-Synchrotron (DESY).

The Python [FabIO](https://github.com/silx-kit/fabio) library, whose formats and reference test
values this package follows, is also MIT-licensed, © European Synchrotron Radiation Facility.

# Fabio.jl

Reading of 2D detector images and their metadata, after the Python
[FabIO](https://github.com/silx-kit/fabio) library. Give it a filename: it works out the
format, handles compression, and hands back the pixels as a Julia array of the type actually
stored in the file, alongside the header.

**Status: Phase 1 complete.** The core architecture is complete, and readers exist for Bruker,
CBF, d\*TREK/ADSC, EDF, Esperanto, mar345, TIFF (plain, Pilatus and MarCCD) and NumPy. See [DESIGN.md](DESIGN.md) for the full architecture and the format roadmap.

```julia
using Fabio, Statistics

frame = Fabio.readimage("image.edf")
mean(frame)                                       # an ImageFrame is an AbstractArray
maximum(frame)
getheader(header(frame), "ESRFCurrent", Float64)  # typed header access

Fabio.openimage("series.edf") do file             # multi-frame files are AbstractVectors
    length(file)
    for f in file
        println(f.fileindex, ": ", maximum(f))
    end
end

Fabio.info("scan.esperanto")                      # a `fabio_info`-style dump
```

## What is here

| Piece | File |
|---|---|
| Formats: Bruker, CBF, d\*TREK/ADSC, EDF, Esperanto, mar345, TIFF/Pilatus/MarCCD, NumPy | `src/formats/` |
| Codecs: raw, zlib blob, AGI bitfield, CBF byte-offset, mar345 PCK | `src/codecs.jl`, `src/agi.jl`, `src/byteoffset.jl`, `src/pck.jl` |
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
  julia --project=. -e 'using Pkg; Pkg.test()'
```

Those testsets check real frames against reference statistics produced by FabIO itself — a
2048² AGI-bitfield Esperanto frame and a 2300² mar345 frame — and assert that the threaded
row-indexed AGI decoder agrees with the sequential one across a whole frame. The mar345 files
are the dataset the FabIO documentation uses for its file-series example, Zenodo
[10.5281/zenodo.2546760](https://doi.org/10.5281/zenodo.2546760).

## Performance

Measured on an 8-thread machine, against FabIO on the same files.

Decoding one 2048² AGI bitfield frame (Esperanto):

| | per frame |
|---|---|
| FabIO — its AGI decoder is pure Python; the Cython extension only covers compression | 793 ms |
| Fabio.jl, sequential | 9.7 ms |
| Fabio.jl, row-indexed across 8 threads | 1.2 ms |

Reading one 2300² PCK frame (mar345), end to end:

| | per frame |
|---|---|
| FabIO, with its Cython PCK decoder | 612 ms |
| Fabio.jl | 38 ms |

The PCK comparison is the fairer of the two, since here FabIO is compiled rather than
interpreted.

The threaded path uses the per-row offset table stored at the end of every AGI blob. FabIO
reads that table and discards it (`# read data components (row indices are ignored)`), which
forces its decoder to walk rows strictly in order. Keeping it also lets each row's start be
validated before use, and makes region-of-interest reads possible without decoding the whole
frame.

A full pass over 140 real files (2048², ~3.2 MB each) takes **0.99 s**.

## Interoperability

The CBF reader and writer are checked against the Python FabIO in both directions: FabIO reads
a CBF written here, and this package reads a CBF written by FabIO, with the arrays identical in
each case. The Esperanto and mar345 readers are checked against reference statistics — minimum,
maximum, sum, mean, standard deviation and individual pixel values — produced by FabIO from real
detector files.

## Licence

MIT — see [LICENSE](LICENSE). Copyright 2026 Graeme Andrew Stewart and Deutsches
Elektronen-Synchrotron (DESY).

The Python [FabIO](https://github.com/silx-kit/fabio) library, whose formats and reference test
values this package follows, is also MIT-licensed, © European Synchrotron Radiation Facility.

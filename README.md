# Fabio.jl

Reading of 2D detector images and their metadata, after the Python
[FabIO](https://github.com/silx-kit/fabio) library. Give it a filename: it works out the
format, handles compression, and hands back the pixels as a Julia array of the type actually
stored in the file, alongside the header.

**Status: Phase 0.** The core architecture is complete and the EDF, Esperanto and NumPy
readers are working. See [DESIGN.md](DESIGN.md) for the full architecture and the format roadmap.

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
| Formats: EDF, Esperanto, NumPy `.npy` | `src/formats/` |
| Codecs: raw, zlib blob, AGI bitfield | `src/codecs.jl`, `src/agi.jl` |
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
Formats with their own decoding libraries (TIFF, HDF5) override `Fabio.readframe` instead and
still inherit everything else.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite is self-contained: it writes its own fixtures rather than downloading anything. Real
detector data is opt-in, since it is generally not redistributable:

```bash
FABIO_JL_LOCAL_TESTDATA=/path/to/esperanto/files julia --project=. -e 'using Pkg; Pkg.test()'
```

That testset checks a real 2048² AGI-bitfield frame against reference statistics produced by
FabIO itself, and asserts that the threaded row-indexed decoder agrees with the sequential one
across the whole frame.

## Performance

Decoding one 2048² AGI bitfield frame, measured on an 8-thread machine:

| | per frame |
|---|---|
| FabIO (its AGI decoder is pure Python — the Cython extension only covers compression) | 793 ms |
| Fabio.jl, sequential | 9.7 ms |
| Fabio.jl, row-indexed across 8 threads | 1.2 ms |

The threaded path uses the per-row offset table stored at the end of every AGI blob. FabIO
reads that table and discards it (`# read data components (row indices are ignored)`), which
forces its decoder to walk rows strictly in order. Keeping it also lets each row's start be
validated before use, and makes region-of-interest reads possible without decoding the whole
frame.

A full pass over 140 real files (2048², ~3.2 MB each) takes **0.99 s**.

## Licence

MIT — see [LICENSE](LICENSE). Copyright 2026 Graeme Andrew Stewart and Deutsches
Elektronen-Synchrotron (DESY).

The Python [FabIO](https://github.com/silx-kit/fabio) library, whose formats and reference test
values this package follows, is also MIT-licensed, © European Synchrotron Radiation Facility.

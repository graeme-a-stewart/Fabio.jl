# Fabio.jl

Reading of 2D detector images and their metadata, after the Python
[FabIO](https://github.com/silx-kit/fabio) library. Give it a filename: it works out the
format, handles compression, and hands back the pixels as a Julia array of the type actually
stored in the file, alongside the header.

**Status: Phase 2 in progress.** Readers exist for Bruker (86 and 100), CBF, d\*TREK/ADSC,
DM3, EDF, Esperanto, Fit2D (binary and mask), GE, KCD, mar345, MPA, MRC, Netpbm, OXD,
R-AXIS, SPE, TIFF (plain, Pilatus and MarCCD), Xcalibur and NumPy. **Phase 2 is complete.** See [DESIGN.md](DESIGN.md) for the full architecture and the format roadmap.

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
| Formats: Bruker (86, 100), CBF, DM3, d\*TREK/ADSC, EDF, Esperanto, Fit2D (binary, mask), GE, KCD, mar345, MPA, MRC, Netpbm, OXD, R-AXIS, SPE, TIFF/Pilatus/MarCCD, Xcalibur, NumPy | `src/formats/` |
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

The mar345 files are the dataset the FabIO documentation uses for its file-series example,
Zenodo [10.5281/zenodo.2546760](https://doi.org/10.5281/zenodo.2546760).

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

## What has been checked against real files

Not every reader is equally trustworthy, and the difference is worth knowing before you rely on
one. A round-trip through this package's own writer only shows that its reader and writer agree
with each other; it says nothing about whether either matches the format. The table separates
the two.

| Reader | Real files | What was compared |
|---|---|---|
| Pilatus / TIFF | 72 | pixels and checksum; **1934 of 1934 header entries identical** |
| MarCCD | 360 | pixels and checksum; all 19 binary-header fields; writer output read back by FabIO |
| Bruker 100 | 22637 read, 151 vs FabIO | pixels and checksum; every correction path exercised |
| Bruker 86 | 6 | pixels and checksum |
| d\*TREK / ADSC | 1424 read, 119 vs FabIO | pixels and checksum; **3193 of 3193 header entries identical**; both byte orders |
| MRC | 10 EMDB | pixels on the 8 FabIO can open; header settled against the data itself |
| Esperanto | 140 | min, max, sum, mean, standard deviation and pixel values |
| mar345 | 4 (Zenodo 2546760) | min, max, sum, mean, standard deviation and pixel values |
| CBF | — | **bidirectional**: FabIO reads what this writes, and this reads what FabIO writes |
| TIFF, multi-strip | 6 fixtures | written by [tifffile](https://github.com/cgohlke/tifffile); both strip layouts |
| GE | 3 (hexrd examples) | pixels and checksum; the 6144 + 2048 split header; blanked-header geometry corroborated by a frame cache |
| TIFF, `Float32` samples | 1 (hexrd examples) | pixels against FabIO |
| EDF, NumPy | — | round-trip only |
| KCD | 286 | pixels and checksum; **525 of 525 header entries identical** |
| Xcalibur | — | struct parsing agrees with FabIO's own `CcdCharacteristiscs.read`, which its image reader never calls |
| R-AXIS | 1 | pixels against FabIO |
| OXD | 4 | pixels against FabIO; TY1 checked against an uncompressed twin of the same image |
| DM3 | 1 | 2048² Float32, pixels against FabIO |
| SPE | 3 | one-frame, two-frame and cropped; pixels against FabIO |
| Fit2D binary | 2 | pixels against FabIO — and these settled the byte order |
| Fit2D mask | 2 | pixels against FabIO, including a 123×456 non-word-aligned mask |
| MPA | 1 | pixels against FabIO — this one found a bug |
| **Netpbm** | **none** | **round-trip only** |

Netpbm is the only reader left resting entirely on this package's own writer, and it is the
one where that matters least: the format is a header of four fields and a raster, and any
`netpbm` or ImageMagick tool writes an independent fixture in one command.

Those real files came from the archive FabIO's own test suite downloads,
`http://www.edna-site.org/pub/fabio/testimages`. Three small ones are committed here (see
`test/data/fabio/PROVENANCE.md`); the rest are opt-in through `FABIO_JL_FABIOTEST`. 

## Defects found in FabIO along the way

Recorded because they affect anyone using FabIO for these formats, and because several of them
are why a comparison had to be done indirectly.

- **MRC header fields.** FabIO reads all 56 header words as `Int32` and names only the first
  thirty, so the cell dimensions, density statistics and origin are meaningless and the `MAP`
  stamp is looked for at word 27 instead of word 53. Its own check that `MAP` reads back as
  `"MAP "` therefore never succeeds; it logs at info level and continues. This reader follows
  MRC2014, which the files confirm: `DMIN`, `DMAX` and `DMEAN` are stored statistics of the
  pixel data and agree with it to full float precision, and the cell angles read exactly 90°.
- **MRC frame access.** `get_frame(n)` and `getframe(n)` raise `AttributeError` for any frame,
  because both copy the deprecated `dim1` attribute onto a frame whose `data` is still `None`.
  Only `fabio.open(path, frame=n)` works.
- **MRC labels.** The ten 80-character labels are decoded as strict UTF-8, so two of the ten
  EMDB files tested cannot be opened at all. This reader maps bytes to codepoints.
- **MarCCD header.** `fabio.open` never exposes it. `TifImage.read` calls
  `MarccdImage._readheader`, which parses the 3072-byte struct into `self.header`, and then
  `_read_with_tiffio` overwrites `self.header` with the TIFF tags. Reaching the fields requires
  calling `marccdimage.interpret_header` directly.
- **Xcalibur cannot read anything.** `XcaliburImage.read` is the unmodified
  `templateimage.py` boilerplate: it ignores the file, builds a 50×60 array and then raises
  `AttributeError`, since the template's `self.uint16` is not an attribute. The struct
  definitions and `CcdCharacteristiscs.loads` beside it are complete and correct — nothing
  ever connected them to the reader.
- **Fit2D reals.** `hex_to(stg, "float")` never looks at `stg`; it returns a hardcoded constant
  of about 1e-4, so every real-valued field in every `.f2d` file reads back as the same number.
- **Fit2D block size.** For files not written in 512-byte blocks, the larger size is worked out
  and the file seeks back to the start, but the stale block already read is then parsed instead
  of the scan resuming.
- **Fit2D byte order.** `i` and `r` arrays are decoded in the machine's native order while `l`
  masks are decoded big-endian, in the same function, so the same file gives different pixels on
  different machines. Real files show little-endian is right for the arrays, which is what this
  package now does; on a big-endian machine FabIO would misread them.
- **SPE frame count.** `SpeImage` never sets `_nframes`, so a two-frame file reports
  `nframes = 1` while its own header says `num_frames = 2`. Both frames are readable through
  `fabio.open(path, frame=n)`.

## Licence

MIT — see [LICENSE](LICENSE). Copyright 2026 Graeme Andrew Stewart and Deutsches
Elektronen-Synchrotron (DESY).

The Python [FabIO](https://github.com/silx-kit/fabio) library, whose formats and reference test
values this package follows, is also MIT-licensed, © European Synchrotron Radiation Facility.

# What has been checked against real files

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
| Netpbm | 6 | written by the netpbm toolkit; checked against the source arithmetic and netpbm's own conversions |
| HDF5, Eiger | 1 real, 3 fixtures | pixels, min, max, sum and an **exact integer** checksum; all three Eiger layouts |
| HDF5, flat container | 1 real, 2 fixtures | pixels and checksum against FabIO, with and without the `::` separator |
| HDF5, LImA and Lambda | 3 fixtures | pixels and the `detector` header field, against FabIO |
| HDF5, sparsify-Bragg | 2 fixtures | densified frames compared with FabIO's own densify, pixel by pixel |

**Every reader here has now been checked against files this package did not write.**

The Netpbm fixtures come from the netpbm toolkit itself and are checked without reference to
FabIO, which reads only P5 of the six: it rejects the plain P2 with "Size spec in pnm-header
does not match size of image data" and fails on both bitmaps. The expected values are instead
the arithmetic fed to netpbm, and netpbm's own conversions between the encodings, which have to
decode identically.

The HDF5 fixtures are written by the test suite itself and then handed to FabIO, which reads
all seven and agrees on all 22 frames; the two real files are from the
[hexrd](https://github.com/HEXRD/hexrd) examples tree. LImA and sparse are cross-checked
against fixtures written by h5py rather than by this package, because FabIO cannot read the
ones written from Julia at all — see the string-attribute defect in
[fabio-py-defects.md](fabio-py-defects.md).

Those real files came from the archive FabIO's own test suite downloads,
`http://www.edna-site.org/pub/fabio/testimages`. Three small ones are committed here (see
`test/data/fabio/PROVENANCE.md`); the rest are opt-in through `FABIO_JL_FABIOTEST`. 

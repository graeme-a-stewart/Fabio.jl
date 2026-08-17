# Status and handover

Written at the close of Phase 2, as a place to pick the work up from. [README.md](README.md)
is the user-facing description and [DESIGN.md](DESIGN.md) the architecture; this file is the
working state that lives in neither.

## Where things stand

23 formats, all reading, two also writing. Phases 0, 1 and 2 of the roadmap in `DESIGN.md` are
complete. `git log` is 26 commits, the working tree is clean, and the last commit is
`c8a3f20`.

| | |
|---|---|
| source | ~6900 lines across `src/` |
| tests | ~4100 lines, **869 assertions** in the self-contained suite |
| committed fixtures | 228 KB across `test/data/{fabio,netpbm,tiff}` |
| opt-in real-data assertions | several thousand more, depending on which datasets are present |

Read-only: bruker, bruker100, cbf, dm3, dtrek, edf, esperanto, fit2d, ge, kcd, mar345, mpa,
mrc, npy, oxd, pilatus, pnm, raxis, spe, tiff, xcalibur. Read and write: fit2dmask, marccd.

**Every reader has been checked against files this package did not write.** The table in
README.md says what each was checked against; the short version is that nine were checked
against real detector data supplied by the user, seven against FabIO's test archive, and the
rest against tifffile, the netpbm toolkit, or FabIO in both directions.

## Running the tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

That is self-contained. The real-data testsets are opt-in, and on this machine the data is at:

```bash
FABIO_JL_LOCAL_TESTDATA=/Users/graemes/code/ansible-kafka/data/202607_compression_test/01_enstatite_data \
FABIO_JL_MAR345_TESTDATA=/Users/graemes/Downloads \
FABIO_JL_PILATUS_TESTDATA=/Users/graemes/code/ansible-kafka/data/RAW_Tutorial_Data/calibration_data \
FABIO_JL_MARCCD_TESTDATA=/Users/graemes/code/ansible-kafka/data/mccd_data \
FABIO_JL_SFRM_TESTDATA=/Users/graemes/code/ansible-kafka/data/sfrm_data \
FABIO_JL_ADSC_TESTDATA=/Users/graemes/code/ansible-kafka/data/ADSC_data \
FABIO_JL_MRC_TESTDATA=/Users/graemes/code/ansible-kafka/data/MRC_data \
FABIO_JL_KCD_TESTDATA=/Users/graemes/code/ansible-kafka/data/KCD_data/zenodo.2593670 \
FABIO_JL_HEXRD_EXAMPLES=/Users/graemes/code/ansible-kafka/data/GE_data/examples \
FABIO_JL_FABIOTEST=/path/to/downloaded/fabio/testimages \
  julia --project=. -e 'using Pkg; Pkg.test()'
```

`FABIO_JL_FABIOTEST` needs the archive fetched first — it is not on this machine permanently:

```bash
U=http://www.edna-site.org/pub/fabio/testimages
for f in mgzn-20hpt.img.bz2 b191_1_9_1.img b191_1_9_1_uncompressed.img d80_60s.img \
         100nmfilmonglass_1_1.img ref_d20x_310mm.dm3.bz2 v3.spe.bz2 v3_2frames.spe.bz2 \
         v3_custom_roi.spe.bz2 Pilatus1M.f2d.bz2 mpa_test.mpa; do curl -sSLO "$U/$f"; done
```

Then `bunzip2 -k *.bz2`. Two notes: `100nmfilmonglass_1_1.img` is served bzip2-compressed under
a `.img` name and must be decompressed and renamed to `100nmfilmonglass_1_1.real.img`, which is
what the test expects; and `random.msk` on that server returns an HTML error page, not a file.

## How validation is done here

The pattern throughout has been to compare against the Python FabIO reading the same file, using
an ephemeral environment so nothing is installed permanently:

```bash
uv run --quiet --with fabio --with numpy python3 -c "import fabio; ..."
```

Set `UV_HTTP_TIMEOUT=300`; the default 30 s is not enough for its dependencies.

Two habits worth keeping. Compare with a **position-sensitive checksum** — the sum of each value
times its flat index — as well as minimum, maximum and sum, because a transposition or a
reordered strip leaves all three aggregates unchanged. And **generate expected values from the
reference implementation** rather than typing them; every time they were typed by hand in this
work they were wrong, and in every such case the reader already agreed with FabIO.

## Open questions

- **OXD TY5 row reset.** FabIO restarts a row every `NY` pixels, using the slow dimension where
  the row length is the fast one; this package restarts every `NX`. The only TY5 file available
  is 1024 square, so it cannot separate the two. A non-square TY5 file would settle it.
- **Fit2D `l`-type masks.** The byte order of `i` and `r` arrays was settled by real files
  (little-endian), but FabIO decodes `l` masks big-endian in the same function and no file of
  that kind was to hand.
- **MarCCD goniostat fields beyond the first few.** Only fields anchored at the start of one of
  the header's fixed-size sections are read, because the section offsets are certain while a
  running field count is not.
- **Compression is detected by extension, not magic.** A gzip or bzip2 file under a misleading
  name is not recognised — `100nmfilmonglass_1_1.img` above is exactly that case. FabIO has the
  same limitation. Detecting `BZh` and `\x1f\x8b` by magic would be a small, strictly better
  change.
- **Tiled TIFF** is refused with a clear message but not implemented, as is **BigTIFF**.
- **Compressed TIFF** (LZW, PackBits, Deflate) is not implemented; compression is per strip, so
  such files are also multi-strip.

## What is next

Phase 3 is the HDF5 family — Eiger, Lima, Lambda, sparse and generic NeXus — through a package
extension on `HDF5.jl`. That is the first real exercise of the weak-dependency design in
`Project.toml`, and the first format family that genuinely needs tier 2 (`readframe`), since an
HDF5 dataset cannot be described as a byte range. `test/data/` has no HDF5 fixtures; the hexrd
examples tree at `FABIO_JL_HEXRD_EXAMPLES` contains several `.h5` files, and FabIO's archive has
`sample_water0000.h5` used by its own tutorial.

Phase 4 is the parity polish: writers for the formats that lack them, the `coerce` matrix,
`FileSeries`, FileIO.jl registration, `ImageMetadata`, and a `fabio-convert` equivalent.

Also outstanding, smaller: the use-case suite in `DESIGN.md` §16 — every example from the FabIO
documentation translated to Julia — was specified but never written as `test/usecases.jl`.

## Process notes

Two mistakes were made repeatedly in this work and are worth not repeating.

**Scripted edits that fail silently.** Several commits claimed README changes that never
happened, because they used Python `str.replace`, which returns the text unchanged when the
anchor does not match and reports nothing. Use `Edit`, which fails loudly, or assert the anchor
matched before writing. The same failure hid a missing `include` in `runtests.jl` for a whole
commit, so 36 tests that were claimed had never run.

**Numbers written from memory.** Reference values, test counts and totals were more than once
stated without measuring. Measure them.

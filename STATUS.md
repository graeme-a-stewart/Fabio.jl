# Status and handover

Written at the close of Phase 3, as a place to pick the work up from. [README.md](README.md)
is the user-facing description and [DESIGN.md](DESIGN.md) the architecture; this file is the
working state that lives in neither.

## Where things stand

28 readers across 24 registry entries, two of them also writing. Phases 0 through 3 of the
roadmap in `DESIGN.md` are complete.

| | |
|---|---|
| source | ~7000 lines across `src/`, ~800 more in `ext/` |
| tests | ~4500 lines, **948 assertions** in the self-contained suite |
| committed fixtures | 228 KB across `test/data/{fabio,netpbm,tiff}` |
| opt-in real-data assertions | several thousand more, depending on which datasets are present |

Read-only: bruker, bruker100, cbf, dm3, dtrek, edf, esperanto, fit2d, ge, hdf5 (eiger, lima,
lambda, sparse, generic), kcd, mar345, mpa, mrc, npy, oxd, pilatus, pnm, raxis, spe, tiff,
xcalibur. Read and write: fit2dmask, marccd.

**Every reader has been checked against files this package did not write.** The table in
README.md says what each was checked against.

## Running the tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

That is self-contained — the HDF5 fixtures are written by the suite itself with HDF5.jl. The
real-data testsets are opt-in, and on this machine the data is at:

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

`FABIO_JL_HEXRD_EXAMPLES` now drives the real HDF5 tests as well as the GE ones. Comparing
pixels in the real Eiger file needs its bitshuffle filter, which is not a test dependency:
without `H5Zbitshuffle` installed the suite checks the file's structure, asserts that the read
fails naming the filter, and logs that the pixels were not compared. With it, that testset goes
from 23 assertions to 31. To run it that way:

```bash
julia --project=. -e 'using Pkg; Pkg.add("H5Zbitshuffle")'
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
uv run --quiet --with fabio --with numpy --with h5py python3 -c "import fabio; ..."
```

Set `UV_HTTP_TIMEOUT=300`; the default 30 s is not enough for its dependencies. The version
validated against in Phase 3 was FabIO 2026.6.0.

Two habits worth keeping. Compare with a **position-sensitive checksum** — the sum of each value
times its flat index — as well as minimum, maximum and sum, because a transposition or a
reordered strip leaves all three aggregates unchanged. For the Eiger frames this is done in
`BigInt` on both sides, so there is no floating-point slack at all. And **generate expected
values from the reference implementation** rather than typing them; every time they were typed
by hand in this work they were wrong, and in every such case the reader already agreed with
FabIO.

For HDF5 specifically, `FABIO_JL_H5_FIXTURE_DIR` makes `test_hdf5.jl` write its fixtures to a
stable directory instead of a temporary one, which is how they were handed to FabIO. That is
the reproducible route back to the cross-check:

```bash
FABIO_JL_H5_FIXTURE_DIR=/tmp/h5fix julia --project=. -e 'using Pkg; Pkg.test()'
```

FabIO reads seven of those fixtures and agrees on all 22 frames — but only through
`fabio.open(path, frame=n)`, because the elder Eiger layout cannot be opened any other way, and
only for the flavours whose detection does not depend on string attributes. LImA and sparse were
cross-checked against h5py-written fixtures instead; see the string-attribute defect in the
README. That asymmetry is a property of FabIO, not of the fixtures.

## Open questions

- **No `*_master.h5` file was available.** The Eiger reader is validated against a data file
  with `/entry/data/data` directly. A master file reaches its data through external links and
  virtual datasets, and while HDF5 resolves both transparently — so the reader needs no code for
  it — that has not been *demonstrated* here. FabIO's archive has `sample_water0000.h5`, used by
  its own tutorial, which would settle it.
- **No real LImA, Lambda or sparse file** was available either; all three are validated against
  fixtures only, though sparse is checked against FabIO's own densify output.
- **The noisy sparse path is untestable against FabIO.** `densify(...; noisy = true)` redraws
  the background from a normal distribution, and Julia and numpy draw from different generators.
  It is implemented and documented as not bit-comparable.
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
- **The extension-absent path is not tested automatically**, because `Pkg.test()` always has
  HDF5 available. It was verified by hand, and is worth a subprocess test if it is to stay
  honest:

  ```bash
  julia --project=. -e 'using Fabio; Fabio.openimage("some.h5")'
  # UnsupportedFormatError: file "some.h5" is HDF5; run `using HDF5` to enable this reader
  ```

## What is next

Phase 4, the parity polish: writers for the formats that lack them, the `coerce` matrix,
`FileSeries`, FileIO.jl registration, `ImageMetadata`, and a `fabio-convert` equivalent. Of
these, `FileSeries` is the one the design has the most to say about — §4.2 drops FabIO's
ambiguous `next()` in favour of `open_series`, and §16.5–16.7 are written against it.

Also outstanding, and now the last piece of the acceptance criteria: the use-case suite in
`DESIGN.md` §16 — every example from the FabIO documentation translated to Julia — was
specified but never written as `test/usecases.jl`. §16.9 and §16.10 are HDF5 examples and are
newly runnable as of this phase.

## Process notes

Three mistakes were made repeatedly in this work and are worth not repeating.

**Scripted edits that fail silently.** Several commits claimed README changes that never
happened, because they used Python `str.replace`, which returns the text unchanged when the
anchor does not match and reports nothing. Use `Edit`, which fails loudly, or assert the anchor
matched before writing — `perl -0777 -i -pe '$n += s{...}{...}; die unless $n == 1'` does that
and was used throughout Phase 3. The same failure hid a missing `include` in `runtests.jl` for a
whole commit, so 36 tests that were claimed had never run.

**Interpolation eaten by the editing tool.** The flip side of the above: a perl replacement is
double-quoted, so `$file` and `@ref` inside the *replacement* text vanish silently. They must be
escaped. This produced two broken strings in Phase 3 that were caught only by reading the result
back, which is the argument for printing the changed region after every edit.

**Numbers written from memory.** Reference values, test counts and totals were more than once
stated without measuring. Measure them.

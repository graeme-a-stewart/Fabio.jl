# Status and handover

Written at the close of Phase 4, as a place to pick the work up from. [README.md](README.md)
is the user-facing description and [DESIGN.md](DESIGN.md) the architecture; this file is the
working state that lives in neither.

## Where things stand

**Status: Phase 4 complete — the roadmap in `DESIGN.md` is finished.** 28 readers across 24
registry entries, 15 of which also write, plus conversion, file series, normalised metadata,
FileIO.jl registration and a command-line converter.

All eleven use cases in `DESIGN.md` §16 now run as `test/usecases.jl`, none skipped. That was
the completeness criterion §14 set at the outset: *"If the documented fabio examples all have
working Julia counterparts, the port is functionally complete."*

| | |
|---|---|
| source | 8384 lines across `src/`, 900 more in `ext/` |
| tests | 5755 lines, **1569 assertions** in the self-contained suite |
| committed fixtures | 228 KB across `test/data/{fabio,netpbm,tiff}` |
| opt-in real-data assertions | several thousand more, depending on which datasets are present |
| history | 40 commits, HEAD `c40858f` |

Read-only (9): bruker100, dm3, esperanto, hdf5 (eiger, lima, lambda, sparse, generic),
mar345, oxd, pilatus, raxis, xcalibur. Read and write (15): bruker, cbf, dtrek, edf, fit2d,
fit2dmask, ge, kcd, marccd, mpa, mrc, npy, pnm, spe, tiff.

The registry's `writer` flag is **derived** from whether a `writeformat` method exists, not
declared, and a test asserts the two agree for every format. It had drifted before that: it
claimed two writable formats when fifteen could write.

**Every reader has been checked against files this package did not write.**
[docs/validation.md](docs/validation.md) says what each was checked against.

### What Phase 4 added

| | where | notes |
|---|---|---|
| `writeimage` | `src/write.jl` | one entry point over the 15 per-format writers; `writeformat` is the extension point |
| `convertimage` | `src/write.jl` | `coerce` plus header translation; `layoutkeys` (15 methods) says which keys describe a file rather than an experiment |
| `FileSeries` | `src/series.jl` | `open_series`, and filename arithmetic as a separate utility |
| `ImageMetadata` | `src/metadata.jl` | `normalise`, 8 formats, SI units |
| FileIO.jl | `ext/FabioFileIOExt.jl` | 20 formats registered, generated from the registry |
| `fabio-convert` | `src/cli.jl`, `bin/fabio-convert` | FabIO's options and exit codes |

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

`FABIO_JL_LOCAL_TESTDATA` and `FABIO_JL_KCD_TESTDATA` now also drive the real-file checks of
the normalised-metadata layer, and `FABIO_JL_HEXRD_EXAMPLES` the real HDF5 tests as well as the
GE ones. Comparing pixels in the real Eiger file needs its bitshuffle filter, which *is* a test
dependency now (`H5Zbitshuffle` in the test target), taking that testset from 23 assertions
to 31.

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
validated against in Phases 3 and 4 was FabIO 2026.6.0.

Three habits worth keeping.

**Compare with a position-sensitive checksum** — the sum of each value times its flat index —
as well as minimum, maximum and sum, because a transposition or a reordered strip leaves all
three aggregates unchanged. For the Eiger frames this is done in `BigInt` on both sides, so
there is no floating-point slack at all.

**Generate expected values from the reference implementation** rather than typing them; every
time they were typed by hand in this work they were wrong, and in every such case the reader
already agreed with FabIO.

**Prefer a check the physics can settle.** The metadata layer's units were confirmed by what
the numbers turned out to be, not by reading a specification: Bruker's `WAVELEN` reads
1.541840 Å, which is Cu Kα, and KCD's `Alpha1` reads 0.709300 Å, which is Mo Kα1. d\*TREK
records its beam centre in millimetres, alone among these formats, and dividing by that file's
pixel size puts it at pixel (1543, 1501) of a 3072-square detector — the middle. A wrong scale
factor does not land on a characteristic emission line or at the centre of a detector.

For HDF5 specifically, `FABIO_JL_H5_FIXTURE_DIR` makes `test_hdf5.jl` write its fixtures to a
stable directory instead of a temporary one, which is how they were handed to FabIO:

```bash
FABIO_JL_H5_FIXTURE_DIR=/tmp/h5fix julia --project=. -e 'using Pkg; Pkg.test()'
```

FabIO reads seven of those fixtures and agrees on all 22 frames — but only through
`fabio.open(path, frame=n)`, because the elder Eiger layout cannot be opened any other way, and
only for the flavours whose detection does not depend on string attributes. LImA and sparse were
cross-checked against h5py-written fixtures instead; see the string-attribute defect in
[docs/fabio-py-defects.md](docs/fabio-py-defects.md). That asymmetry is a property of FabIO, not
of the fixtures.

## Open questions

Carried forward, and still true:

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
  change. Note this now cuts both ways: `writeimage` compresses on a `.gz` destination, so the
  two are at least symmetric.
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

New with Phase 4:

- **Most writers are still "minimal".** Their own docstrings say so — "enough to round-trip data
  and to give the test suite a dependency-free fixture". They write a correct file of the kind
  the matching reader expects, and MarCCD's output has been read back by FabIO, but they do not
  cover every option of every format. `writeimage` makes them reachable and uniform; it does not
  make them complete. Deepening one is per-format work, and the natural next task.
- **Bruker's `DISTANC` unit is taken from the format's documentation**, not from anything the
  files here could prove: 4.996016 in the sample file is read as centimetres, giving 50 mm,
  which is plausible for a lab source but not decisive. `CENTER` in pixels *is* confirmed by the
  data (382 of 768 columns, 508 of 1024 rows).
- **Bruker's pixel size is deliberately unset.** It is derivable from the pixels-per-centimetre
  figure inside `DETTYPE`, but that field's layout varies by detector, and a wrong number would
  be worse than `nothing`.
- **`normalise` covers 8 formats of 24**, and timestamps only two (d\*TREK and Bruker). The
  others return `nothing`, which is the documented and correct outcome, but there is easy work
  here for anyone who wants a format covered.
- **Type inference stops at the frame table.** `readframe` reaches its descriptor through
  `ImageFile.frames::Vector{FrameSpec}`, whose parameter is abstract, so the element type is
  recovered at run time rather than inferred. `DESIGN.md` §8 claims frames are inferred; that is
  true of `pixeltype(file)` and of the layout fast path, not of `readframe`'s return type. The
  cost is one dispatch per frame, against reading a whole frame, so it has been left alone —
  but the design document overstates it.
- **The CLI omits `-i/--interactive` and `--remove-destination`**, deliberately: prompting has
  no place in something meant for pipelines, and `--force` covers the latter.

## What is next

The roadmap is complete, so what follows is a choice rather than a queue. In rough order of
value:

1. **Deepen the writers.** The largest honest gap. `writeimage` is uniform over fifteen formats
   whose writers are mostly fixture-grade; making EDF, CBF and TIFF genuinely complete
   (multi-frame EDF, CBF's MD5 and CIF round-tripping, TIFF compression) would let the registry
   claim them without the caveat the README currently carries.
2. **Settle the open questions above that only need a file** — a non-square TY5, an `l`-type
   Fit2D mask, a real LImA or Lambda file, an Eiger master file.
3. **Detect compression by magic**, not extension. Small, strictly better, and FabIO shares the
   limitation.
4. **Registration and release.** The package has a UUID and a version of `0.1.0-DEV`; nothing
   has been tagged or registered. Aqua.jl and JET.jl were named in `DESIGN.md` §14 and have
   never been run.
5. **Documentation.** There is no `docs/` build — Documenter.jl was in the original structure
   sketch and is not set up. The docstrings are written for it.
6. **Performance beyond the two codecs measured.** [docs/performance.md](docs/performance.md)
   covers AGI bitfield and PCK only; nothing else has been profiled, and the threaded
   bulk-conversion path in §16.8 has never been benchmarked against FabIO's ~28 frames/s.

## Process notes

Four mistakes were made repeatedly in this work and are worth not repeating.

**Scripted edits that fail silently.** Several commits claimed README changes that never
happened, because they used Python `str.replace`, which returns the text unchanged when the
anchor does not match and reports nothing. Use `Edit`, which fails loudly, or assert the anchor
matched before writing — `perl -0777 -i -pe '$n += s{...}{...}; die unless $n == 1'` does that
and was used throughout Phases 3 and 4. The same failure hid a missing `include` in
`runtests.jl` for a whole commit, so 36 tests that were claimed had never run. A variant of it
appeared again in Phase 4: a substitution matched *twice* and duplicated an `include` line,
which only the printed result revealed.

**Interpolation eaten by the editing tool.** The flip side of the above: a perl replacement is
double-quoted, so `$file`, `@ref` and `$(x)` inside the *replacement* text vanish silently. They
must be escaped. This produced several broken strings across Phases 3 and 4 — including one in a
`@warn` that then printed the mangled text at every load — and every one was caught only by
reading the result back. Print the changed region after every edit.

**Catching an exception and carrying on.** The FileIO extension's first version wrapped
registration in a bare `catch ... continue`. It reported zero formats registered as though
nothing had happened, and hid a real argument-type error for a round of testing. Warn, or let
it throw; do not swallow. The warning is what then identified a genuine magic-number clash.

**Numbers written from memory.** Reference values, test counts and totals were more than once
stated without measuring. Measure them. Every number in this file was measured on the commit it
describes.

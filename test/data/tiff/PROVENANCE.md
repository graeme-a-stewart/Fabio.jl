# Multi-strip TIFF fixtures

These six files exist because the multi-strip TIFF paths could not otherwise be tested against
anything but this package's own writer, which would only prove that the reader and writer
share an interpretation of the format rather than that either is right.

## How they were made

The pixel data is synthetic — two arrays of random integers, seeded with
`numpy.random.default_rng(7)` — so nothing here is third-party data and all six are covered by
this package's MIT licence.

The files were **written by [tifffile](https://github.com/cgohlke/tifffile)**, an independent
implementation that knows nothing about this package, using an explicit `rowsperstrip` to force
several strips:

| file | source array | strips | layout | notes |
|---|---|---|---|---|
| `tf_u16_rps4.tif` | 40×32 `uint16` | 10 | contiguous | `rowsperstrip=4` |
| `tf_i32_rps3.tif` | 24×18 `int32` | 8 | contiguous | `rowsperstrip=3`, signed |
| `tf_u16_be.tif` | 40×32 `uint16` | 8 | contiguous | `rowsperstrip=5`, big-endian |
| `scatter_rev.tif` | 40×32 `uint16` | 10 | **non-contiguous** | strips in reverse file order |
| `scatter_i32.tif` | 24×18 `int32` | 8 | **non-contiguous** | strips in reverse file order |
| `scatter_be.tif` | 40×32 `uint16` | 8 | **non-contiguous** | reverse order, big-endian |

The three `scatter_*` files start as the tifffile output above and have their strips relocated:
each strip is moved to the end of the file, separated by 32 bytes of padding and written in
reverse order, with the `StripOffsets` table rewritten to match. Only the strip *placement* is
synthesised; the IFD, the tag encoding and the pixel bytes are all tifffile's.

That step is necessary because tifffile — and Pillow, and the detector software behind every
real file this package has been tested against — writes strips consecutively. A contiguous
multi-strip image is described by a single `BinaryLayout` and takes the ordinary tier-1 path,
so genuinely disjoint strips had to be constructed to reach the gathering path at all.

## What they are checked against

Every one of the six was read by the Python FabIO, and the reference minimum, maximum, sum and
position-sensitive checksum embedded in `test/test_tiff_strips.jl` are FabIO's values.

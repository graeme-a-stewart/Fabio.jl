# Netpbm fixtures written by the netpbm toolkit

Six files, 24 KB in total, written by **Netpbm 11.2.27** — the reference implementation of the
format, and an implementation that knows nothing about this package. They exist because Netpbm
was the last reader here with no check beyond a round-trip through this package's own writer.

| file | subformat | shape | how it was made |
|---|---|---|---|
| `grad_p5_8bit.pgm` | P5 binary | 37×23 `UInt8` | a plain P2 gradient through `pnmtopnm` |
| `grad_p5_16bit.pgm` | P5 binary | 37×23 `UInt16` | a plain P2 with `MAXVAL 65535` through `pnmtopnm` |
| `grad_p2_ascii.pgm` | P2 ASCII | 37×23 | `pnmtoplainpnm` of `grad_p5_8bit.pgm` |
| `bits_p4.pbm` | P4 packed | 29×13 | `pbmmake -g 29 13` |
| `bits_p1.pbm` | P1 ASCII | 29×13 | `pnmtoplainpnm` of `bits_p4.pbm` |
| `grey_p5.pgm` | P5 binary | 16×12 | `pgmmake 0.5 16 12`, a uniform 128 |

Netpbm is freely redistributable, and the content is synthetic — a arithmetic gradient and a
generated checkerboard — so nothing here is third-party data.

## What each one is for

The pixel values are known three ways over, without reference to FabIO:

- The two gradients are `(7x + 11y) mod 256` and `(1234x + 4321y + 7) mod 65536`, the exact
  values handed to Netpbm, so the decoded image can be compared against arithmetic.
- `grad_p2_ascii.pgm` and `grad_p5_8bit.pgm` are the same image in the two encodings, converted
  by Netpbm itself, so they must decode identically. `bits_p1.pbm` and `bits_p4.pbm` likewise.
- `grey_p5.pgm` is uniform 128 by construction.

The 16-bit gradient earns its place specifically. Scaling an 8-bit image to 16 bits multiplies
by 257, which makes every sample a byte palindrome — `v*257 = v<<8 | v` — so such a file cannot
tell a big-endian reader from a little-endian one. These values were chosen instead to be
asymmetric, and the file therefore proves that Netpbm writes samples most significant byte
first, as the specification requires.

## Two things these files exposed

`bits_p1.pbm` broke this package's reader. Netpbm writes a plain PBM as an unseparated run of
digits, `0101…`, since the format allows whitespace between pixels but does not require it. The
decoder was reading whitespace-delimited tokens, so an entire row parsed as one enormous
number. A plain PBM pixel is a single character, and the decoder now treats it as one.

FabIO cannot read three of the six at all: `grad_p2_ascii.pgm` raises "Size spec in pnm-header
does not match size of image data", and both bitmaps fail outright, so in practice its Netpbm
support is P5 only. That is why the checks here are against Netpbm's own conversions and the
source arithmetic rather than against FabIO.

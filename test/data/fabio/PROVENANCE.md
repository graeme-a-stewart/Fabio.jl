# Real detector files from FabIO's test collection

Three small files taken from the archive FabIO's own test suite downloads,
`http://www.edna-site.org/pub/fabio/testimages`, and committed here because they are the only
real files this package has for these two formats and they are small enough to carry.

| file | format | size | what it exercises |
|---|---|---|---|
| `fit2d.f2d` | Fit2D binary | 14.5 KB | a real record stream, and the byte order (below) |
| `face.msk` | Fit2D mask | 8.1 KB | a 123×456 mask, non-square and not a whole word wide |
| `fit2d_click.msk` | Fit2D mask | 129 KB | a 1024×1024 mask with a handful of pixels set |

FabIO is MIT-licensed, © European Synchrotron Radiation Facility, as is this package, so
redistributing them here carries no additional condition. They are unmodified.

## Why `fit2d.f2d` in particular

The `.f2d` reader was written with no real file to check against, and its byte order could not
be settled from FabIO's source: FabIO decodes `i` and `r` arrays in the machine's **native**
order while decoding `l` masks explicitly as **big-endian**, in the same function. This package
originally followed the deliberate big-endian branch, and recorded the uncertainty.

This file settles it. Read big-endian it yields denormals — a maximum of 1.8e-38 where FabIO
reports 1793 — and read little-endian it matches FabIO exactly on minimum, maximum and sum.
The default is little-endian because of this file, which is why it is worth 14 KB in the repo.

## Larger files not committed

The same archive holds real files for the other formats, too large to carry here but worth
knowing about when a reader changes:

    mgzn-20hpt.img.bz2            R-AXIS,  2300×1280
    b191_1_9_1.img                OXD TY1, 512×512, with an uncompressed twin
    b191_1_9_1_uncompressed.img   OXD raw, the same image
    d80_60s.img                   OXD,     2048×2048
    100nmfilmonglass_1_1.img      OXD,     1024×1024  (served bzip2-compressed under a .img name)
    ref_d20x_310mm.dm3.bz2        DM3,     2048×2048 Float32
    v3.spe, v3_2frames.spe        SPE,     one and two frames
    v3_custom_roi.spe             SPE,     a cropped region
    Pilatus1M.f2d                 Fit2D,   981×1043
    mpa_test.mpa                  MPA,     1024×1024 with three data blocks

# Formats and extending

```@meta
CurrentModule = Fabio
```

## Formats

Every format is a singleton type used only for dispatch. `Fabio.formats()` lists them with
their extensions and whether each can be written.

```@docs
Bruker
CBF
DM3
Dtrek
EDF
Esperanto
Fit2D
Fit2DMask
GE
KCD
Mar345
MPA
MRC
NPY
OXD
PNM
Raxis
SPE
TIFFLike
Xcalibur
```

## Formats and detection

```@docs
ImageFormat
NexusLike
register!
formats
formatnames
findformat
FormatEntry
Magic
detectformat
refine
```

## Extending

The two tiers of the extension interface, and the hooks around them.

```@docs
scan
readframe
readframe_layout
writeformat
writeone
openstate
closestate
needs_random_access
BinaryLayout
FrameSpec
HDF5Slice
SparseFrame
```

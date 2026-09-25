# Series and metadata

```@meta
CurrentModule = Fabio
```

## File series

```@docs
open_series
FileSeries
seriesfiles
framesperfile
seriespaths
nextfile
prevfile
jumpfile
filenumber
splitfilenumber
```

## Normalised metadata

```@docs
normalise
ImageMetadata
```

## EDF SPEC mnemonics

SPEC writes motor positions, counters and the sample's orientation into EDF headers as pairs of
parallel lists. These read them the way silx does when it presents an EDF file as NeXus.

```@docs
edfmnemonics
hasedfsample
edfsample
```

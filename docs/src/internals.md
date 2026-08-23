# Sources, codecs and errors

```@meta
CurrentModule = Fabio
```

## Sources and codecs

```@docs
AbstractSource
MmapSource
BufferSource
opensource
splitfragment
sourcefragment
AbstractDataCodec
RawBlob
ZlibBlob
ByteOffset
AGIBitfield
PCK
decode
readblob
mmapblob
```

## Byte order and orientation

```@docs
ByteOrder
Orientation
```

## Checksums

```@docs
verifychecksum
md5
md5hex
md5base64
```

## Command line

```@docs
main
```

## Errors

```@docs
FabioError
UnknownFormatError
UnsupportedFormatError
CorruptFileError
TruncatedFileError
```

## Modules

```@docs
Fabio.Fabio
```

The two package extensions, which load with `using HDF5` and `using FileIO`. An extension
module is reachable only through `Base.get_extension`, so `make.jl` binds both names before
building.

```@meta
CurrentModule = Main
```

```@docs
FabioHDF5Ext.FabioHDF5Ext
FabioFileIOExt.FabioFileIOExt
```

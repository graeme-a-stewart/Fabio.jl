# Reading

```@meta
CurrentModule = Fabio
```

## Reading

```@docs
openimage
readimage
readheader
readheaders
readframe!
framestack
framesize
pixeltype
info
```

## Frames and headers

```@docs
ImageFrame
Header
header
data
getheader
imageformat
rowmajor
imageview
ImageFile
fileheader
istruncated
```

## Data URLs

The addresses silx uses for data in files, with `getdata` as the counterpart of
`silx.io.get_data`. A URL's slice is 0-based and numpy-ordered, exactly as silx writes it;
[`juliaindices`](@ref) converts it.

```@docs
DataUrl
getdata
isvalid(::DataUrl)
scheme
filepath
datapath
dataslice
invalidreason
isabsolute
urlstring
slicestring
SliceRange
SliceEllipsis
juliaindices
getdataset
```

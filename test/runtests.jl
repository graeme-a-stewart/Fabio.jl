using Test
using Fabio
using Fabio: Header, getheader, getci, Magic, matches, register!, formats, formatnames
using Fabio:
    RawBlob, ZlibBlob, AGIBitfield, decode, encode, BinaryLayout, LittleEndian, BigEndian
using Fabio: opensource, bytes, filesize, framestack, readframe!, framesize
using Fabio: writeedf, writenpy, edfheadertext, coerce, scan, detectformat
using Statistics
using CodecZlib: GzipCompressor
using TranscodingStreams: transcode

const TMP = mktempdir()

include("test_header.jl")
include("test_registry.jl")
include("test_npy.jl")
include("test_edf.jl")
include("test_agi.jl")
include("test_esperanto.jl")

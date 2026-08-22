using Test
using Fabio
using Fabio: Header, getheader, getci, Magic, matches, register!, formats, formatnames
using Fabio:
    RawBlob, ZlibBlob, AGIBitfield, ByteOffset, decode, encode, BinaryLayout,
    LittleEndian, BigEndian
using Fabio: opensource, bytes, filesize, framestack, readframe!, framesize
using Fabio: writeedf, writenpy, writecbf, edfheadertext, coerce, scan, detectformat
using Statistics
using Dates: DateTime
using CodecZlib: GzipCompressor
using TranscodingStreams: transcode

const TMP = mktempdir()

include("test_header.jl")
include("test_registry.jl")
include("test_npy.jl")
include("test_edf.jl")
include("test_agi.jl")
include("test_byteoffset.jl")
include("test_cbf.jl")
include("test_pck.jl")
include("test_mar345.jl")
include("test_tiff.jl")
include("test_tiff_strips.jl")
include("test_phase2.jl")
include("test_phase2b.jl")
include("test_fit2d.jl")
include("test_kcd_mpa.jl")
include("test_kcd_real.jl")
include("test_dm3.jl")
include("test_oxd.jl")
include("test_xcalibur.jl")
include("test_fabio_files.jl")
include("test_netpbm_real.jl")
include("test_mrc_real.jl")
include("test_ge_real.jl")
include("test_pilatus_real.jl")
include("test_marccd_real.jl")
include("test_bruker100_real.jl")
include("test_dtrek_real.jl")
include("test_dtrek.jl")
include("test_bruker.jl")
include("test_esperanto.jl")
include("test_write.jl")
include("test_hdf5.jl")
include("test_hdf5_real.jl")
include("test_series.jl")
include("test_metadata.jl")
include("test_fileio.jl")
include("usecases.jl")

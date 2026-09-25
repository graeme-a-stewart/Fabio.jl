"""
    FabioCodecBzip2Ext

Whole-file bzip2 compression (`.bz2`), for reading and writing. Loaded automatically when
the user runs `using CodecBzip2`; see `Fabio.compressioncodec`.
"""
module FabioCodecBzip2Ext

using Fabio
using CodecBzip2: Bzip2Decompressor, Bzip2Compressor

Fabio.compressioncodec(::Val{:bz2}) = (Bzip2Decompressor, Bzip2Compressor)

end # module

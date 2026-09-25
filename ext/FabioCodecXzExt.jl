"""
    FabioCodecXzExt

Whole-file xz compression (`.xz`), for reading and writing. Loaded automatically when
the user runs `using CodecXz`; see `Fabio.compressioncodec`.
"""
module FabioCodecXzExt

using Fabio
using CodecXz: XzDecompressor, XzCompressor

Fabio.compressioncodec(::Val{:xz}) = (XzDecompressor, XzCompressor)

end # module

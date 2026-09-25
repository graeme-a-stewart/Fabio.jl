"""
    FabioCodecZstdExt

Whole-file zstd compression (`.zst`), for reading and writing. Loaded automatically when
the user runs `using CodecZstd`; see `Fabio.compressioncodec`.
"""
module FabioCodecZstdExt

using Fabio
using CodecZstd: ZstdDecompressor, ZstdCompressor

Fabio.compressioncodec(::Val{:zst}) = (ZstdDecompressor, ZstdCompressor)

end # module

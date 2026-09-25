using CodecBzip2, CodecXz, CodecZstd
using CodecZlib: GzipCompressor
using Fabio: sniffcompression, compressioncodec, decompress, compress

@testset "whole-file compression" begin
    A = reshape(Float32.(1:20), 5, 4)
    plain = joinpath(TMP, "cz.edf")
    writeimage(plain, A)
    raw = read(plain)

    @testset "$sfx" for sfx in (".gz", ".bz2", ".xz", ".zst")
        # Writing compresses, reading decompresses.
        p = joinpath(TMP, "cz_written.edf" * sfx)
        writeimage(p, A)
        @test sniffcompression(read(p)[1:min(10, end)]) == sfx
        @test readimage(p) == A
        @test decompress(sfx, read(p)) == raw

        # A compressed file under a name that does not say so is found by its magic bytes.
        disguised = joinpath(TMP, "cz_disguised_$(lstrip(sfx, '.')).edf")
        write(disguised, compress(sfx, raw))
        @test readimage(disguised) == A
        @test Fabio.info(IOBuffer(), disguised) === nothing
    end

    @test compressioncodec(Val(:gz)) !== nothing
    @test compressioncodec(Val(:lz4)) === nothing
    @test sniffcompression(raw[1:10]) == ""
    @test sniffcompression(UInt8[]) == ""
    # "BZh" alone is printable text; a bzip2 stream needs its block or end-of-stream magic.
    @test sniffcompression(Vector{UInt8}("BZh9 is not bzip2")) == ""
    @test sniffcompression(transcode(Bzip2Compressor, UInt8[])) == ".bz2"
    @test_throws ArgumentError decompress(".lz4", raw)
    @test decompress("", raw) === raw
end

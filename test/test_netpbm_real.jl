# Netpbm files written by the netpbm toolkit itself; see test/data/netpbm/PROVENANCE.md.
# The expected values come from the arithmetic fed to netpbm and from netpbm's own
# conversions between the encodings, not from FabIO — which reads only P5 of these six.

const NETPBMDIR = joinpath(@__DIR__, "data", "netpbm")

@testset "Netpbm files written by the netpbm toolkit" begin
    # The exact values handed to netpbm, so the decoded image is checked against arithmetic.
    src8 = UInt8[(7 * (x - 1) + 11 * (y - 1)) % 256 for x = 1:37, y = 1:23]
    src16 = UInt16[(1234 * (x - 1) + 4321 * (y - 1) + 7) % 65536 for x = 1:37, y = 1:23]

    @testset "P5 binary, 8-bit" begin
        frame = Fabio.readimage(joinpath(NETPBMDIR, "grad_p5_8bit.pgm"))
        @test eltype(frame) === UInt8
        @test size(frame) == (37, 23)
        @test collect(frame) == src8
        @test header(frame)["MAXVAL"] == 255
    end

    @testset "P5 binary, 16-bit, big-endian samples" begin
        # Scaling an 8-bit image to 16 bits multiplies by 257 and makes every sample a byte
        # palindrome, which cannot tell the two byte orders apart. These values are
        # deliberately asymmetric, so matching them proves the samples are read most
        # significant byte first, as the specification requires.
        frame = Fabio.readimage(joinpath(NETPBMDIR, "grad_p5_16bit.pgm"))
        @test eltype(frame) === UInt16
        @test size(frame) == (37, 23)
        @test collect(frame) == src16
        @test header(frame)["MAXVAL"] == 65535
        @test collect(frame[1:3, 1]) == UInt16[7, 1241, 2475]
    end

    @testset "P2 ASCII decodes to the same image as P5" begin
        # netpbm converted one into the other, so any difference is this reader's.
        p5 = collect(Fabio.readimage(joinpath(NETPBMDIR, "grad_p5_8bit.pgm")))
        p2 = collect(Fabio.readimage(joinpath(NETPBMDIR, "grad_p2_ascii.pgm")))
        @test p2 == p5
        @test p2 == src8
        @test header(Fabio.readimage(joinpath(NETPBMDIR, "grad_p2_ascii.pgm")))["SUBFORMAT"] == "P2"
    end

    @testset "P1 and P4 bitmaps agree" begin
        # netpbm writes a plain PBM as an unseparated run of digits, since the format allows
        # whitespace between pixels but does not require it. Reading whitespace-delimited
        # tokens swallows a whole row as one enormous number; a pixel is a single character.
        p4 = collect(Fabio.readimage(joinpath(NETPBMDIR, "bits_p4.pbm")))
        p1 = collect(Fabio.readimage(joinpath(NETPBMDIR, "bits_p1.pbm")))
        @test size(p4) == (29, 13)
        @test size(p1) == (29, 13)
        @test p1 == p4
        @test extrema(p4) == (0x00, 0x01)
        # 29 is not a multiple of 8, so the packed rows carry three padding bits that must
        # not leak into the image.
        @test sum(Int.(p4)) == 189
    end

    @testset "a uniform grey" begin
        frame = Fabio.readimage(joinpath(NETPBMDIR, "grey_p5.pgm"))
        @test size(frame) == (16, 12)
        @test all(==(0x80), collect(frame))     # pgmmake 0.5 of 255
    end
end

@testset "byte-offset codec" begin
    @testset "plain 8-bit deltas" begin
        # First pixel is a delta from zero, so the stream is just a difference sequence.
        raw = reinterpret(UInt8, Int8[5, 2, -1, 3])
        out = decode(ByteOffset(), collect(raw), Int32, (4, 1))
        @test out[:, 1] == cumsum(Int32[5, 2, -1, 3])
    end

    @testset "16-bit escape" begin
        raw = vcat(
            reinterpret(UInt8, Int8[1]),
            UInt8[0x80],
            reinterpret(UInt8, [htol(Int16(1000))]),
            reinterpret(UInt8, Int8[-2]),
        )
        out = decode(ByteOffset(), raw, Int32, (3, 1))
        @test out[:, 1] == cumsum(Int32[1, 1000, -2])
    end

    @testset "32-bit escape" begin
        raw = vcat(
            UInt8[0x80],
            reinterpret(UInt8, [htol(typemin(Int16))]),
            reinterpret(UInt8, [htol(Int32(100_000))]),
            reinterpret(UInt8, Int8[7]),
        )
        out = decode(ByteOffset(), raw, Int32, (2, 1))
        @test out[:, 1] == cumsum(Int32[100_000, 7])
    end

    @testset "64-bit escape" begin
        raw = vcat(
            UInt8[0x80],
            reinterpret(UInt8, [htol(typemin(Int16))]),
            reinterpret(UInt8, [htol(typemin(Int32))]),
            reinterpret(UInt8, [htol(Int64(5_000_000_000))]),
        )
        out = decode(ByteOffset(), raw, Int64, (1, 1))
        @test out[1, 1] == 5_000_000_000
    end

    @testset "round-trip across the escalation boundaries" begin
        # Values chosen so consecutive differences land in every escape class.
        A = Int32[0 127; -127 200; 40_000 -40_000; 3_000_000_000 % Int32 0]
        blob = encode(ByteOffset(), A)
        @test decode(ByteOffset(), blob, Int32, size(A)) == A

        for T in (Int8, Int16, Int32, Int64)
            B = rand(T(-100):T(100), 17, 13)
            @test decode(ByteOffset(), encode(ByteOffset(), B), T, size(B)) == B
        end
    end

    @testset "cumulative sum runs across rows, not per row" begin
        # Unlike AGI bitfield, byte-offset accumulates over the whole frame in raster order.
        A = reshape(Int32.(1:12), 3, 4)
        blob = encode(ByteOffset(), A)
        @test decode(ByteOffset(), blob, Int32, (3, 4)) == A
        # A single 0x01 delta per pixel is exactly what that array compresses to.
        @test length(blob) == 12
        @test all(==(0x01), blob)
    end

    @testset "unsigned data wraps like numpy" begin
        A = UInt16[10 20; 30 5]
        blob = encode(ByteOffset(), A)
        @test decode(ByteOffset(), blob, UInt16, size(A)) == A
    end

    @testset "truncated streams are rejected" begin
        @test_throws Fabio.TruncatedFileError decode(
            ByteOffset(),
            reinterpret(UInt8, Int8[1, 2]) |> collect,
            Int32,
            (4, 1),
        )
        @test_throws Fabio.TruncatedFileError decode(ByteOffset(), UInt8[0x80], Int32, (1, 1))
        @test_throws Fabio.TruncatedFileError decode(
            ByteOffset(),
            vcat(UInt8[0x80], reinterpret(UInt8, [htol(typemin(Int16))])),
            Int32,
            (1, 1),
        )
    end
end

using Fabio: writefit2d, Fit2DChunked, Fit2DBitmask, FIT2D_BLOCK

@testset "Fit2D binary (.f2d)" begin
    @testset "round-trip for both array types" begin
        for T in (Int32, Float32)
            A = T <: AbstractFloat ? rand(T, 9, 6) : Int32[10i + j for i = 1:9, j = 1:6]
            p = joinpath(TMP, "rt_$T.f2d")
            writefit2d(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (9, 6)
            @test collect(frame) == A
            @test header(frame)["ImageRecord"] == "data_array"
        end
    end

    @testset "scalar and string records" begin
        p = joinpath(TMP, "records.f2d")
        writefit2d(p, Int32[1 2; 3 4];
            strings = Dict("TITLE" => "a fit2d file"),
            integers = Dict("NPIX" => 4, "NEG" => -7),
            reals = Dict("WAVE" => 0.9793, "DIST" => 125.5))
        h = Fabio.readheader(p)
        @test h["TITLE"] == "a fit2d file"
        @test h["NPIX"] == 4
        @test h["NEG"] == -7
        # FabIO returns a hardcoded 1e-4 for every real field, whatever the digits say.
        @test h["WAVE"] ≈ 0.9793 rtol = 1e-6
        @test h["DIST"] ≈ 125.5 rtol = 1e-6
        @test !(h["WAVE"] ≈ 1.0e-4)
    end

    @testset "records sit on block boundaries" begin
        p = joinpath(TMP, "blocks.f2d")
        writefit2d(p, Int32[1 2; 3 4]; strings = Dict("A" => "x"))
        raw = read(p)
        @test length(raw) % FIT2D_BLOCK == 0
        # Every record's opening block starts with a backslash.
        @test raw[1] == UInt8('\\')
        @test raw[FIT2D_BLOCK+1] == UInt8('\\')
        @test Fabio.readheader(p)["BlockSize"] == FIT2D_BLOCK
    end

    @testset "byte order is explicit and switchable" begin
        # The format does not record its own byte order and FabIO is inconsistent about it,
        # so both readings are available and the assumed one is reported.
        A = Int32[10i + j for i = 1:9, j = 1:6]
        big = joinpath(TMP, "be.f2d")
        little = joinpath(TMP, "le.f2d")
        writefit2d(big, A; bigendian = true)
        writefit2d(little, A; bigendian = false)
        @test read(big) != read(little)

        fb = Fabio.openimage(f -> f[1], big; format = Fabio.Fit2D{:big}())
        fl = Fabio.openimage(f -> f[1], little; format = Fabio.Fit2D{:little}())
        @test collect(fb) == A
        @test collect(fl) == A
        @test header(fb)["ByteOrder"] == "HighByteFirst"
        @test header(fl)["ByteOrder"] == "LowByteFirst"
        # Reading one as the other gives different numbers, which is the point of the switch.
        wrong = Fabio.openimage(f -> f[1], big; format = Fabio.Fit2D{:little}())
        @test collect(wrong) != A
    end

    @testset "the chunked payload codec" begin
        # With a 512-byte block and four-byte pixels every byte is a pixel, so the stride and
        # the kept count coincide. A larger block leaves padding after the first 128 pixels.
        raw = UInt8[]
        for v in Int32.(1:128)
            append!(raw, reinterpret(UInt8, [hton(v)]))
        end
        append!(raw, zeros(UInt8, 512))          # padding of a 1024-byte block
        for v in Int32.(129:130)
            append!(raw, reinterpret(UInt8, [hton(v)]))
        end
        append!(raw, zeros(UInt8, 1024 - 8))
        out = decode(Fit2DChunked(1024, 128, true), raw, Int32, (130, 1))
        @test vec(out) == Int32.(1:130)
    end

    @testset "the bit-mask codec packs 31 pixels per word" begin
        # The sign bit is unused and pixels run in reverse within each word.
        word = UInt32(0)
        for b in (1, 3, 31)                       # pixels 1, 3 and 31
            word |= UInt32(1) << (31 - b)
        end
        raw = collect(reinterpret(UInt8, [hton(word)]))
        out = decode(Fit2DBitmask(), raw, UInt8, (31, 1))
        expected = zeros(UInt8, 31)
        expected[[1, 3, 31]] .= 1
        @test vec(out) == expected
    end

    @testset "detected by the \$FFF_START marker" begin
        p = joinpath(TMP, "detect.f2d")
        writefit2d(p, Int32[1 2; 3 4])
        @test Fabio.openimage(f -> Fabio.imageformat(f), p) isa Fabio.Fit2D
        q = joinpath(TMP, "detect_f2d.dat")
        cp(p, q; force = true)
        @test Fabio.openimage(f -> Fabio.imageformat(f), q) isa Fabio.Fit2D
    end

    @testset "a file with no array record is refused" begin
        p = joinpath(TMP, "noarray.f2d")
        block = rpad("\\\$FFF_START:00000000i00000000", FIT2D_BLOCK)
        write(p, Vector{UInt8}(codeunits(block)))
        @test_throws Fabio.CorruptFileError Fabio.openimage(p)
    end

    @testset "a truncated payload is caught" begin
        p = joinpath(TMP, "short.f2d")
        writefit2d(p, Int32[10i + j for i = 1:9, j = 1:6])
        raw = read(p)
        q = joinpath(TMP, "short2.f2d")
        write(q, raw[1:end-FIT2D_BLOCK])
        @test_throws Fabio.FabioError Fabio.openimage(q)
    end
end

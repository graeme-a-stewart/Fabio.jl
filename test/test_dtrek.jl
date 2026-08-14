using Fabio: writedtrek

@testset "d*TREK / ADSC" begin
    @testset "round-trip, every supported element type" begin
        for T in (Int8, UInt8, Int16, UInt16, Int32, UInt32, Float32)
            A = T <: AbstractFloat ? rand(T, 7, 4) : rand(T(0):T(100), 7, 4)
            p = joinpath(TMP, "rt_$T.img")
            writedtrek(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (7, 4)
            @test collect(frame) == A
        end
    end

    @testset "axis order: SIZE1 is the fast axis" begin
        A = UInt16[1 2 3 4; 5 6 7 8; 9 10 11 12]      # size (3, 4)
        p = joinpath(TMP, "axes.img")
        writedtrek(p, A)
        h = Fabio.readheader(p)
        @test getheader(h, "SIZE1", Int) == 3
        @test getheader(h, "SIZE2", Int) == 4
        frame = Fabio.readimage(p)
        @test size(frame) == (3, 4)
        @test collect(frame) == A
        @test size(Fabio.rowmajor(frame)) == (4, 3)
    end

    @testset "header round-trips" begin
        extra = Header()
        extra["DISTANCE"] = "125.000"
        extra["WAVELENGTH"] = "0.97934"
        extra["DETECTOR_SN"] = "926"
        p = joinpath(TMP, "hdr.img")
        writedtrek(p, UInt16[1 2; 3 4], extra)
        h = Fabio.readheader(p)
        @test getheader(h, "DISTANCE", Float64) == 125.0
        @test getheader(h, "WAVELENGTH", Float64) == 0.97934
        @test h["DETECTOR_SN"] == "926"
        @test getheader(h, "HEADER_BYTES", Int) == 512
        @test h["Data_type"] == "unsigned short int"
    end

    @testset "big-endian data" begin
        A = UInt16[0x0102 0x0304; 0x0506 0x0708]
        p = joinpath(TMP, "be.img")
        writedtrek(p, A; bigendian = true)
        @test Fabio.readheader(p)["BYTE_ORDER"] == "big_endian"
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "detected by magic, ahead of EDF's bare brace" begin
        p = joinpath(TMP, "detect.img")
        writedtrek(p, UInt16[1 2; 3 4])
        # Both formats open with '{'; d*TREK's longer signature has to win.
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), p) === :Dtrek
        q = joinpath(TMP, "detect_dtrek.dat")
        cp(p, q; force = true)
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), q) === :Dtrek
    end

    @testset "older ADSC files without Data_type" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "oldadsc.img")
        writedtrek(p, A)
        raw = String(read(p))
        # The replacement is padded to the same length; anything else shifts the pixels.
        raw = replace(raw, "Data_type=unsigned short int;" => "TYPE=unsigned_short;         ")
        q = joinpath(TMP, "oldadsc2.img")
        write(q, Vector{UInt8}(codeunits(raw)))
        frame = Fabio.readimage(q)
        @test eltype(frame) === UInt16
        @test collect(frame) == A
    end

    @testset "bad headers are refused" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "unsup.img")
        writedtrek(p, A)
        raw = String(read(p))
        q = joinpath(TMP, "unsup2.img")
        write(q, Vector{UInt8}(codeunits(replace(raw, "DIM=2;" => "DIM=3;"))))
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(q)

        r = joinpath(TMP, "unsup3.img")
        write(r, Vector{UInt8}(codeunits(replace(raw, "Data_type=unsigned short int;" => "Data_type=Compressed;        "))))
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(r)
    end
end

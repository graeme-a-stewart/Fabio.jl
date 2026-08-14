using Fabio: writebruker, BrukerBlob

@testset "Bruker" begin
    @testset "round-trip at each pixel width" begin
        for T in (UInt8, UInt16, UInt32)
            A = rand(T(0):T(200), 6, 4)
            p = joinpath(TMP, "rt_$T.sfrm")
            writebruker(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (6, 4)
            @test collect(frame) == A
        end
    end

    @testset "axis order: NCOLS is the fast axis" begin
        A = UInt16[1 2 3 4; 5 6 7 8; 9 10 11 12]      # size (3, 4) -> NCOLS 3, NROWS 4
        p = joinpath(TMP, "axes.sfrm")
        writebruker(p, A)
        h = Fabio.readheader(p)
        @test getheader(h, "NCOLS", Int) == 3
        @test getheader(h, "NROWS", Int) == 4
        frame = Fabio.readimage(p)
        @test size(frame) == (3, 4)
        @test collect(frame) == A
    end

    @testset "80-character line header" begin
        extra = Header()
        extra["DETTYPE"] = "CCD-PXL-KAF2"
        extra["WAVELEN"] = "0.71073 0.71073 0.71073"
        p = joinpath(TMP, "hdr.sfrm")
        writebruker(p, UInt16[1 2; 3 4], extra)
        h = Fabio.readheader(p)
        @test getheader(h, "FORMAT", Int) == 86
        @test getheader(h, "HDRBLKS", Int) == 5
        @test h["DETTYPE"] == "CCD-PXL-KAF2"
        @test h["WAVELEN"] == "0.71073 0.71073 0.71073"
        @test h["datastart"] == 5 * 512
    end

    @testset "repeated keys accumulate across lines" begin
        # Bruker spreads long values over several 80-character lines under the same key.
        extra = Header()
        p = joinpath(TMP, "repeat.sfrm")
        writebruker(p, UInt16[1 2; 3 4], extra)
        raw = read(p)
        line = rpad(rpad("CFR", 7) * ":" * "second part", 80)
        first = rpad(rpad("CFR", 7) * ":" * "first part", 80)
        raw[(7*80+1):(7*80+80)] = Vector{UInt8}(codeunits(first))
        raw[(8*80+1):(8*80+80)] = Vector{UInt8}(codeunits(line))
        q = joinpath(TMP, "repeat2.sfrm")
        write(q, raw)
        h = Fabio.readheader(q)
        @test h["CFR"] == "first part\nsecond part"
    end

    @testset "overflow records widen the image to UInt32" begin
        # NPIXELB of 1 caps stored counts at 255; anything larger rides in the overflow table.
        A = UInt8[1 2 3; 4 5 6]                       # size (2, 3), so flat order 1,4,2,5,3,6
        p = joinpath(TMP, "overflow.sfrm")
        # Positions are 0-based flat indices in raster order, which is this array's memory
        # order: a row-major walk of numpy's (NROWS, NCOLS) and a column-major walk of our
        # (NCOLS, NROWS) visit the pixels in the same sequence.
        writebruker(p, A; overflow = [(0, 70000), (4, 1000)])
        frame = Fabio.readimage(p)
        @test eltype(frame) === UInt32
        @test frame[1] == 70000                       # patched
        @test frame[5] == 1000                        # patched, was 3
        @test frame[2] == 4                           # untouched
        @test frame[6] == 6
    end

    @testset "LINEAR rescales to Float32" begin
        A = UInt16[10 20; 30 40]
        extra = Header()
        extra["LINEAR"] = "2.5 1.0"
        p = joinpath(TMP, "linear.sfrm")
        writebruker(p, A, extra)
        frame = Fabio.readimage(p)
        @test eltype(frame) === Float32
        @test collect(frame) ≈ Float32[26 51; 76 101]
    end

    @testset "an identity LINEAR leaves the type alone" begin
        A = UInt16[1 2; 3 4]
        extra = Header()
        extra["LINEAR"] = "1.0 0.0"
        p = joinpath(TMP, "linear1.sfrm")
        writebruker(p, A, extra)
        frame = Fabio.readimage(p)
        @test eltype(frame) === UInt16
        @test collect(frame) == A
    end

    @testset "FORMAT:100 is refused rather than misread" begin
        # A 100-format file keeps its overflows, underflows and baseline in three separate
        # padded blocks. Reading it as 86 would give plausible-looking wrong pixels, so the
        # reader has to refuse it explicitly.
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "v100.sfrm")
        writebruker(p, A)
        raw = read(p)
        raw[1:80] = Vector{UInt8}(codeunits(rpad(rpad("FORMAT", 7) * ":100", 80)))
        q = joinpath(TMP, "v100b.sfrm")
        write(q, raw)
        err = try
            Fabio.openimage(q)
            nothing
        catch e
            e
        end
        @test err isa Fabio.UnsupportedFormatError
        @test occursin("FORMAT:100", sprint(showerror, err))
    end

    @testset "detected by magic" begin
        p = joinpath(TMP, "detect.sfrm")
        writebruker(p, UInt16[1 2; 3 4])
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), p) === :Bruker
        q = joinpath(TMP, "detect_bruker.dat")
        cp(p, q; force = true)
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), q) === :Bruker
    end

    @testset "truncated files are caught" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "trunc.sfrm")
        writebruker(p, A)
        raw = read(p)
        q = joinpath(TMP, "trunc2.sfrm")
        write(q, raw[1:end-4])
        @test_throws Fabio.TruncatedFileError Fabio.openimage(q)
    end
end

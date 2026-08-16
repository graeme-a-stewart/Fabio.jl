using Fabio: writebruker, BrukerBlob, Bruker100Blob

"""
Write a FORMAT:100 fixture: header, narrow pixels, then the padded underflow, overflow1 and
overflow2 tables in that order. Mirrors the layout `Bruker100Blob` documents.
"""
function write_bruker100(path, A::Matrix{UInt8}; underflow = Int[], overflow1 = UInt16[],
                         overflow2 = Int32[], baseline = 0, hdrblks = 5, ubpp = 1)
    cols, rows = size(A)
    nov0 = isempty(underflow) ? -1 : length(underflow)
    lines = [
        rpad(rpad("FORMAT",7)*":100", 80),
        rpad(rpad("HDRBLKS",7)*":"*string(hdrblks), 80),
        rpad(rpad("NROWS",7)*":"*string(rows), 80),
        rpad(rpad("NCOLS",7)*":"*string(cols), 80),
        rpad(rpad("NPIXELB",7)*":1   "*string(ubpp), 80),
        rpad(rpad("NOVERFL",7)*":"*join((nov0, length(overflow1), length(overflow2)), "   "), 80),
        rpad(rpad("NEXP",7)*":1  0  "*string(baseline)*"  0  0", 80),
    ]
    body = join(lines)
    total = hdrblks * 512
    pad16(v) = 16 * cld(v, 16)
    Base.open(path, "w") do f
        write(f, codeunits(rpad(body, total)))
        write(f, vec(A))
        for (vals, bpp, conv) in ((underflow, ubpp, x -> x), (overflow1, 2, x -> x), (overflow2, 4, x -> x))
            isempty(vals) && continue
            raw = UInt8[]
            for v in vals
                u = bpp == 1 ? UInt8(v % UInt8) : bpp == 2 ? nothing : nothing
                if bpp == 1
                    push!(raw, reinterpret(UInt8, Int8(v)))
                elseif bpp == 2
                    append!(raw, reinterpret(UInt8, [htol(UInt16(v))]))
                else
                    append!(raw, reinterpret(UInt8, [htol(Int32(v))]))
                end
            end
            append!(raw, zeros(UInt8, pad16(length(raw)) - length(raw)))
            write(f, raw)
        end
    end
    return path
end

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

    @testset "FORMAT:100 is detected by refine, not by magic" begin
        A = UInt8[1 2; 3 4]
        p = joinpath(TMP, "v100.sfrm")
        write_bruker100(p, A)
        @test Fabio.openimage(f -> Fabio.imageformat(f), p) isa Fabio.Bruker{100}
        @test collect(Fabio.readimage(p)) == Int32[1 2; 3 4]
    end

    @testset "FORMAT:100 overflow escalates in two stages" begin
        # A pixel reading 255 takes the next overflow1 value; if that value is 65535 it then
        # takes the next overflow2 value. Order matters, so the second stage must see the
        # result of the first.
        A = UInt8[255 1; 2 255]                       # two pixels at the marker
        p = joinpath(TMP, "v100_ov.sfrm")
        write_bruker100(p, A; overflow1 = UInt16[1000, 65535], overflow2 = Int32[123456])
        d = collect(Fabio.readimage(p))
        @test eltype(d) === Int32
        # Flat order is column-major: A[1,1]=255, A[2,1]=2, A[1,2]=1, A[2,2]=255.
        @test d[1] == 1000                            # first marker -> first overflow1
        @test d[2] == 2
        @test d[3] == 1
        @test d[4] == 123456                          # second marker -> 65535 -> overflow2
    end

    @testset "FORMAT:100 underflow and baseline" begin
        # With an underflow table present, zero pixels take its values and every other pixel
        # gains the baseline from NEXP.
        A = UInt8[0 5; 7 0]
        p = joinpath(TMP, "v100_un.sfrm")
        write_bruker100(p, A; underflow = Int[-3, -9], baseline = 64)
        d = collect(Fabio.readimage(p))
        @test d[1] == -3                              # first zero
        @test d[2] == 7 + 64
        @test d[3] == 5 + 64
        @test d[4] == -9                              # second zero
    end

    @testset "FORMAT:100 without an underflow table adds the baseline everywhere" begin
        A = UInt8[0 5; 7 0]
        p = joinpath(TMP, "v100_nb.sfrm")
        write_bruker100(p, A; baseline = 64)          # NOVERFL starts -1, so baseline is 0
        d = collect(Fabio.readimage(p))
        @test d == Int32[0 5; 7 0]
    end

    @testset "FORMAT:100 tables that run short are refused" begin
        A = UInt8[255 255; 255 255]
        p = joinpath(TMP, "v100_short.sfrm")
        write_bruker100(p, A; overflow1 = UInt16[1, 2])   # four markers, two entries
        @test_throws Fabio.CorruptFileError Fabio.readimage(p)
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

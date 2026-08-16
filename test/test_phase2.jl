using Fabio: writepnm, writemrc, writege, PnmASCII, PnmBitmap

@testset "PNM" begin
    @testset "P5 binary greyscale round-trips" begin
        for T in (UInt8, UInt16)
            A = rand(T(0):T(200), 9, 6)
            p = joinpath(TMP, "rt_$T.pgm")
            writepnm(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (9, 6)
            @test collect(frame) == A
            h = header(frame)
            @test h["SUBFORMAT"] == "P5"
            @test h["WIDTH"] == 9
            @test h["HEIGHT"] == 6
            @test h["MAXVAL"] == (T === UInt8 ? 255 : 65535)
        end
    end

    @testset "16-bit samples are big-endian, as netpbm requires" begin
        A = UInt16[0x0102 0x0304; 0x0506 0x0708]
        p = joinpath(TMP, "be.pgm")
        writepnm(p, A)
        @test collect(Fabio.readimage(p)) == A
        # Confirm on the bytes: A[1,1] is 0x0102 and must be stored high byte first.
        raw = read(p)
        payload = raw[(length(raw)-7):end]
        @test payload[1:2] == UInt8[0x01, 0x02]
    end

    @testset "P2 ASCII greyscale" begin
        A = UInt16[10 20 30; 40 50 60]
        p = joinpath(TMP, "ascii.pgm")
        writepnm(p, A; ascii = true, comment = "written by the test suite")
        frame = Fabio.readimage(p)
        @test collect(frame) == A
        @test header(frame)["SUBFORMAT"] == "P2"
    end

    @testset "comments are kept, being the format's only metadata" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "comments_meta.pgm")
        text = "CREATOR: Fabio.jl\nexposure 1.5 s\nwavelength 0.9793"
        writepnm(p, A; comment = text)
        h = Fabio.readheader(p)
        @test h["Comments"] == text
        @test split(h["Comments"], "\n")[2] == "exposure 1.5 s"
        # Feeding the recovered comments back reproduces the file exactly.
        q = joinpath(TMP, "comments_meta2.pgm")
        writepnm(q, collect(Fabio.readimage(p)); comment = h["Comments"])
        @test read(p) == read(q)
        # A file without comments gets no Comments entry rather than an empty one.
        r = joinpath(TMP, "nocomment.pgm")
        writepnm(r, A)
        @test !haskey(Fabio.readheader(r), "Comments")
    end

    @testset "comments and split lines in the header" begin
        # Netpbm allows '#' comments anywhere and does not care how fields are split.
        body = "P5\n# a comment\n4\n# another\n3\n255\n"
        pix = UInt8[10i + j for j = 1:3 for i = 1:4]
        p = joinpath(TMP, "comments.pgm")
        Base.open(p, "w") do io
            write(io, codeunits(body))
            write(io, pix)
        end
        frame = Fabio.readimage(p)
        @test size(frame) == (4, 3)
        @test vec(collect(frame)) == pix
        @test header(frame)["Comments"] == "a comment\nanother"
    end

    @testset "P4 packed bitmap" begin
        # One bit per pixel, rows padded to a byte; a set bit is black, so it reads as 0.
        p = joinpath(TMP, "bits.pbm")
        Base.open(p, "w") do io
            write(io, codeunits("P4\n10 2\n"))
            write(io, UInt8[0b10110000, 0b01000000, 0b00001111, 0b11000000])
        end
        frame = Fabio.readimage(p)
        @test size(frame) == (10, 2)
        @test eltype(frame) === UInt8
        @test collect(frame[:, 1]) == UInt8[0, 1, 0, 0, 1, 1, 1, 1, 1, 0]
        @test collect(frame[:, 2]) == UInt8[1, 1, 1, 1, 0, 0, 0, 0, 0, 0]
    end

    @testset "P1 ASCII bitmap" begin
        p = joinpath(TMP, "bits.ascii.pbm")
        write(p, Vector{UInt8}(codeunits("P1\n4 2\n1 0 0 1\n0 1 1 0\n")))
        frame = Fabio.readimage(p)
        @test size(frame) == (4, 2)
        @test collect(frame[:, 1]) == UInt8[0, 1, 1, 0]
        @test collect(frame[:, 2]) == UInt8[1, 0, 0, 1]
    end

    @testset "colour subformats are refused, not misread" begin
        for magic in ("P3", "P6", "P7")
            p = joinpath(TMP, "colour_$magic.pnm")
            write(p, Vector{UInt8}(codeunits("$magic\n2 2\n255\n" * "\0"^12)))
            @test_throws Fabio.UnsupportedFormatError Fabio.openimage(p)
        end
    end

    @testset "truncated data is caught" begin
        p = joinpath(TMP, "short.pgm")
        Base.open(p, "w") do io
            write(io, codeunits("P5\n8 8\n255\n"))
            write(io, zeros(UInt8, 10))          # needs 64
        end
        @test_throws Fabio.TruncatedFileError Fabio.openimage(p)
    end
end

@testset "MRC" begin
    @testset "single and multi-section round-trip" begin
        for T in (Int8, Int16, UInt16, Float32)
            frames = [T <: AbstractFloat ? rand(T, 7, 5) : rand(T(0):T(50), 7, 5) for _ = 1:3]
            p = joinpath(TMP, "rt_$T.mrc")
            writemrc(p, frames)
            file = Fabio.openimage(p)
            try
                @test length(file) == 3
                @test Fabio.pixeltype(file) === T
                for i = 1:3
                    @test collect(file[i]) == frames[i]
                    @test size(file[i]) == (7, 5)
                end
            finally
                close(file)
            end
        end
    end

    @testset "header follows the MRC2014 field types" begin
        p = joinpath(TMP, "hdr.mrc")
        writemrc(p, [Int16[1 2; 3 4]]; labels = ["written by the test suite"])
        h = Fabio.readheader(p)
        @test h["NX"] == 2 && h["NY"] == 2 && h["NZ"] == 1
        @test h["MODE"] == 1
        @test h["MAP"] == "MAP "                    # word 53, not word 27 as FabIO has it
        @test h["ByteOrder"] == "LowByteFirst"
        # Cell edges and angles are Float32 in the spec, so they must read as real numbers.
        @test h["CELL_A"] ≈ 2.0
        @test h["CELL_ALPHA"] ≈ 90.0
        @test h["DMIN"] ≈ 1.0
        @test h["DMAX"] ≈ 4.0
        @test startswith(h["LABEL_00"], "written by")
    end

    @testset "complex modes are refused" begin
        p = joinpath(TMP, "cplx.mrc")
        writemrc(p, [Int16[1 2; 3 4]])
        raw = read(p)
        raw[13:16] = reinterpret(UInt8, [htol(Int32(4))])     # MODE = 4, complex
        q = joinpath(TMP, "cplx2.mrc")
        write(q, raw)
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(q)
    end

    @testset "a short stack is reported, not read past the end" begin
        p = joinpath(TMP, "shortstack.mrc")
        writemrc(p, [Int16[1 2; 3 4] for _ = 1:4])
        raw = read(p)
        q = joinpath(TMP, "shortstack2.mrc")
        write(q, raw[1:end-16])                                # lose two sections
        file = @test_logs (:warn,) match_mode = :any Fabio.openimage(q)
        try
            @test length(file) == 2
            @test collect(file[1]) == Int16[1 2; 3 4]
        finally
            close(file)
        end
    end
end

@testset "GE" begin
    @testset "multi-frame round-trip" begin
        frames = [UInt16[10i+j+k for i = 1:5, j = 1:4] for k = 1:3]
        p = joinpath(TMP, "rt.ge")
        writege(p, frames)
        file = Fabio.openimage(p)              # detected by its ADEPT tag
        try
            @test Fabio.imageformat(file) isa GE
            @test length(file) == 3
            @test Fabio.pixeltype(file) === UInt16
            for i = 1:3
                @test collect(file[i]) == frames[i]
                @test size(file[i]) == (5, 4)
            end
            h = header(file[1])
            @test h["NumberOfFrames"] == 3
            @test h["NumberOfColsInFrame"] == 5     # the fast axis
            @test h["NumberOfRowsInFrame"] == 4
            @test h["ImageDepthInBits"] == 16
            @test h["HeaderBlanked"] === false
        finally
            close(file)
        end
    end

    @testset "the blanked-header fallback constants" begin
        # These are the geometry a blanked GE file has to be read with, since its header says
        # nothing. They are corroborated by a hexrd frame-cache of real GE detector data,
        # whose metadata records shape [2048, 2048], dtype uint16 and panel "GE", and by
        # FabIO reading a blanked file written with them and finding the same frames.
        @test Fabio.GE_DEFAULT_ROWS == 2048
        @test Fabio.GE_DEFAULT_COLS == 2048
        @test Fabio.GE_DEFAULT_DEPTH == 16
        @test Fabio.GE_DEFAULT_HEADER_BYTES == 8192
    end

    @testset "a blanked header falls back to the APS geometry" begin
        # The APS firmware writes the header as zeros; the frame count then has to come from
        # the file size, and the geometry from what that detector is known to produce.
        frames = [zeros(UInt16, 2048, 2048) for _ = 1:2]
        frames[1][1, 1] = 0x1234
        frames[2][2048, 2048] = 0x4321
        p = joinpath(TMP, "blank.ge")
        writege(p, frames; blanked = true)
        file = Fabio.openimage(p)              # detected by its run of zero bytes
        try
            @test Fabio.imageformat(file) isa GE
            @test length(file) == 2
            h = header(file[1])
            @test h["HeaderBlanked"] === true
            @test h["NumberOfRowsInFrame"] == 2048
            @test size(file[1]) == (2048, 2048)
            @test file[1][1, 1] == 0x1234
            @test file[2][2048, 2048] == 0x4321
        finally
            close(file)
        end
    end

    @testset "an over-claimed frame count is trimmed with a warning" begin
        frames = [UInt16[1 2; 3 4] for _ = 1:3]
        p = joinpath(TMP, "overclaim.ge")
        writege(p, frames)
        raw = read(p)
        write(joinpath(TMP, "overclaim2.ge"), raw[1:end-8])    # drop a frame
        file = @test_logs (:warn,) match_mode = :any Fabio.openimage(
            joinpath(TMP, "overclaim2.ge"))
        try
            @test length(file) == 2
        finally
            close(file)
        end
    end
end

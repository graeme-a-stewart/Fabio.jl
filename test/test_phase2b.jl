using Fabio: writefit2dmask, writespe, Fit2DMaskBits, RaxisPM, RAXIS_FIELDS, RAXIS_HEADER_BYTES

@testset "Fit2D mask" begin
    @testset "round-trip at sizes that do and do not fill a word" begin
        for (d1, d2) in ((32, 4), (33, 5), (7, 3), (100, 60))
            A = UInt8.(rand(Bool, d1, d2))
            p = joinpath(TMP, "mask_$(d1)x$(d2).msk")
            writefit2dmask(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === UInt8
            @test size(frame) == (d1, d2)
            @test collect(frame) == A
        end
    end

    @testset "rows start on a four-byte boundary" begin
        # 33 pixels need two Int32 words per row, so each row occupies 8 bytes and 31 bits
        # are padding. A reader using ceil(d1/8) bytes instead would drift row by row.
        d1, d2 = 33, 5
        A = zeros(UInt8, d1, d2)
        A[33, :] .= 1                       # the last pixel of every row
        p = joinpath(TMP, "boundary.msk")
        writefit2dmask(p, A)
        @test filesize(p) == 1024 + 8 * d2
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "bits run least significant first" begin
        # Opposite to a Netpbm P4 bitmap. Masking pixel 1 alone must set bit 0 of the first
        # byte, so that byte reads 0x01 rather than 0x80.
        A = zeros(UInt8, 8, 1)
        A[1, 1] = 1
        p = joinpath(TMP, "lsb.msk")
        writefit2dmask(p, A)
        @test read(p)[1025] == 0x01
        A2 = zeros(UInt8, 8, 1)
        A2[8, 1] = 1
        writefit2dmask(p, A2)
        @test read(p)[1025] == 0x80
    end

    @testset "detected by its MASK stamp" begin
        p = joinpath(TMP, "detect.msk")
        writefit2dmask(p, UInt8[1 0; 0 1])
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), p) === :Fit2DMask
        q = joinpath(TMP, "detect_mask.dat")
        cp(p, q; force = true)
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), q) === :Fit2DMask
    end

    @testset "anything non-zero masks" begin
        out = Fabio.coerce(Fit2DMask(), Int32[0 5; -3 0])
        @test out == UInt8[0 1; 1 0]
        p = joinpath(TMP, "coerce.msk")
        writefit2dmask(p, Float64[0.0 2.5; 0.0 0.0])
        @test collect(Fabio.readimage(p)) == UInt8[0 1; 0 0]
    end

    @testset "a file without the stamp is refused" begin
        p = joinpath(TMP, "nomask.msk")
        write(p, vcat(zeros(UInt8, 1024), zeros(UInt8, 16)))
        @test_throws Fabio.CorruptFileError Fabio.openimage(p; format = Fit2DMask())
    end
end

@testset "R-AXIS" begin
    """Build an R-AXIS file: big-endian header, pixels at the end."""
    function write_raxis(path, A::Matrix{UInt16}; ratio = 1.0, extra = Dict{String,Any}())
        hdr = zeros(UInt8, RAXIS_HEADER_BYTES)
        hdr[1:6] = Vector{UInt8}(codeunits("R-AXIS"))
        put32(off, v::Integer) = (hdr[(off+1):(off+4)] = reinterpret(UInt8, [hton(Int32(v))]))
        putf32(off, v) = (hdr[(off+1):(off+4)] = reinterpret(UInt8, [hton(Float32(v))]))
        putstr(off, s, len) =
            (hdr[(off+1):(off+len)] = Vector{UInt8}(codeunits(rpad(s, len)))[1:len])
        put32(768, size(A, 1))
        put32(772, size(A, 2))
        putf32(800, ratio)
        putstr(0, "R-AXIS", 10)
        putstr(10, "4", 10)
        for (off, name, width, kind) in RAXIS_FIELDS
            haskey(extra, name) || continue
            kind == Fabio.RaxisF32 ? putf32(off, extra[name]) :
            kind == Fabio.RaxisI32 ? put32(off, extra[name]) : putstr(off, extra[name], width)
        end
        Base.open(path, "w") do f
            Base.write(f, hdr)
            Base.write(f, reinterpret(UInt8, hton.(vec(A))))
        end
        return path
    end

    @testset "plain frames stay UInt16" begin
        A = UInt16[10i + j for i = 1:9, j = 1:6]
        p = joinpath(TMP, "plain.osc")
        write_raxis(p, A)
        frame = Fabio.readimage(p)
        @test Fabio.openimage(f -> Fabio.imageformat(f), p) isa Raxis
        @test eltype(frame) === UInt16
        @test size(frame) == (9, 6)
        @test collect(frame) == A
        @test header(frame)["PhotomultiplierApplied"] === false
    end

    @testset "the header is read big-endian" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "hdr.osc")
        write_raxis(p, A; ratio = 8.0,
            extra = Dict{String,Any}("Wavelength" => 1.5418, "Crystal-to-detector Distance" => 200.0,
                                     "IP Number" => 3))
        h = Fabio.readheader(p)
        @test h["X Pixels"] == 2
        @test h["Y Pixels"] == 2
        @test h["Photomultiplier Ratio"] ≈ 8.0
        @test h["InstrumentType"] == "R-AXIS"
        @test h["Version"] == "4"
        @test h["IP Number"] == 3
        @test h["Wavelength"] ≈ 1.5418 rtol = 1e-6
        @test h["Crystal-to-detector Distance"] ≈ 200.0
    end

    @testset "the photomultiplier escape widens the frame" begin
        # Bit 15 marks a scaled value: clear it and multiply by the ratio.
        A = UInt16[100 200; (0x8000 | 300) 400]
        p = joinpath(TMP, "pm.osc")
        write_raxis(p, A; ratio = 8.0)
        frame = Fabio.readimage(p)
        @test eltype(frame) === UInt32
        @test header(frame)["PhotomultiplierApplied"] === true
        @test collect(frame) == UInt32[100 200; 2400 400]     # 300 * 8
    end

    @testset "pixels are located from the end of the file" begin
        # A longer-than-minimum header must not shift the data: the pixel block is anchored
        # to EOF, so padding inserted after the header is skipped by construction.
        A = UInt16[7 8; 9 10]
        p = joinpath(TMP, "tail.osc")
        write_raxis(p, A)
        raw = read(p)
        padded = joinpath(TMP, "tail_padded.osc")
        write(padded, vcat(raw[1:RAXIS_HEADER_BYTES], zeros(UInt8, 600), raw[(RAXIS_HEADER_BYTES+1):end]))
        @test collect(Fabio.readimage(padded)) == A
    end
end

@testset "SPE" begin
    @testset "multi-frame round-trip at every data type" begin
        for T in (Float32, Int32, Int16, UInt16)
            frames = [T <: AbstractFloat ? rand(T, 6, 4) : rand(T(0):T(50), 6, 4) for _ = 1:3]
            p = joinpath(TMP, "rt_$T.spe")
            writespe(p, frames)
            file = Fabio.openimage(p)
            try
                @test Fabio.imageformat(file) isa SPE
                @test length(file) == 3
                @test Fabio.pixeltype(file) === T
                for i = 1:3
                    @test collect(file[i]) == frames[i]
                    @test size(file[i]) == (6, 4)
                end
            finally
                close(file)
            end
        end
    end

    @testset "version 2 header fields" begin
        p = joinpath(TMP, "hdr.spe")
        writespe(p, [Int16[1 2; 3 4]]; exposure = 2.5, date = "01Jan2020", time = "123456")
        h = Fabio.readheader(p)
        @test h["version"] == 2
        @test h["x_dim"] == 2
        @test h["y_dim"] == 2
        @test h["data_type"] == 2
        @test h["num_frames"] == 1
        @test h["exposure_time"] ≈ 2.5
        @test h["date"] == "01Jan2020"
        @test h["time"] == "123456"
        @test h["xml_offset"] == 0
        @test !haskey(h, "xml")
    end

    @testset "version 3 keeps the XML footer verbatim" begin
        # A non-zero offset at byte 678 marks version 3; the footer is captured rather than
        # parsed, since extracting from it would need an XML dependency.
        frames = [Int16[1 2; 3 4]]
        p = joinpath(TMP, "v3.spe")
        writespe(p, frames)
        raw = read(p)
        xml = "<SpeFormat><Calibrations/></SpeFormat>"
        xmloff = length(raw)
        raw[679:686] = reinterpret(UInt8, [htol(Int64(xmloff))])
        q = joinpath(TMP, "v3b.spe")
        write(q, vcat(raw, Vector{UInt8}(codeunits(xml))))
        h = Fabio.readheader(q)
        @test h["version"] == 3
        @test h["xml_offset"] == xmloff
        @test h["xml"] == xml
        @test collect(Fabio.readimage(q)) == frames[1]
    end

    @testset "an over-claimed frame count is trimmed" begin
        frames = [Int16[1 2; 3 4] for _ = 1:3]
        p = joinpath(TMP, "over.spe")
        writespe(p, frames)
        raw = read(p)
        q = joinpath(TMP, "over2.spe")
        write(q, raw[1:end-8])
        file = @test_logs (:warn,) match_mode = :any Fabio.openimage(q)
        try
            @test length(file) == 2
        finally
            close(file)
        end
    end

    @testset "unknown data types are refused" begin
        p = joinpath(TMP, "badtype.spe")
        writespe(p, [Int16[1 2; 3 4]])
        raw = read(p)
        raw[109:110] = reinterpret(UInt8, [htol(UInt16(9))])
        q = joinpath(TMP, "badtype2.spe")
        write(q, raw)
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(q; format = SPE())
    end
end

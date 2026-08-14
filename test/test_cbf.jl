@testset "CBF" begin
    @testset "round-trip" begin
        for T in (Int16, Int32, UInt16, UInt32)
            A = rand(T(0):T(1000), 9, 6)
            p = joinpath(TMP, "rt_$T.cbf")
            writecbf(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (9, 6)
            @test collect(frame) == A
        end
    end

    @testset "detected by magic" begin
        p = joinpath(TMP, "detect.cbf")
        writecbf(p, Int32[1 2; 3 4])
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), p) === :CBF
        # …and still detected when the extension lies.
        q = joinpath(TMP, "detect_cbf.dat")
        cp(p, q; force = true)
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), q) === :CBF
    end

    @testset "axis order follows the binary section header" begin
        A = Int32[1 2 3 4; 5 6 7 8; 9 10 11 12]     # size (3, 4)
        p = joinpath(TMP, "axes.cbf")
        writecbf(p, A)
        h = Fabio.readheader(p)
        @test getheader(h, "X-Binary-Size-Fastest-Dimension", Int) == 3
        @test getheader(h, "X-Binary-Size-Second-Dimension", Int) == 4
        frame = Fabio.readimage(p)
        @test size(frame) == (3, 4)
        @test collect(frame) == A
        @test size(Fabio.rowmajor(frame)) == (4, 3)
    end

    @testset "MIME and CIF headers are both exposed" begin
        extra = Header()
        extra["_diffrn_radiation_wavelength.wavelength"] = "0.9793"
        extra["_array_data.array_id"] = "image_1"
        p = joinpath(TMP, "hdr.cbf")
        writecbf(p, Int32[1 2; 3 4], extra)
        h = Fabio.readheader(p)
        @test getheader(h, "_diffrn_radiation_wavelength.wavelength", Float64) == 0.9793
        @test h["_array_data.array_id"] == "image_1"
        @test h["X-Binary-Element-Type"] == "signed 32-bit integer"
        @test h["conversions"] == "x-CBF_BYTE_OFFSET"
        @test getheader(h, "X-Binary-Number-of-Elements", Int) == 4
    end

    @testset "Pilatus comment metadata is parsed" begin
        # Pilatus keeps its instrument metadata in `# key value` comments rather than CIF
        # data items, so a reader that only handles `_key` loses all of it.
        A = Int32[1 2; 3 4]
        blob = encode(ByteOffset(), A)
        text = """
        ###CBF: VERSION 1.5

        data_pilatus

        _array_data.header_convention "PILATUS_1.2"
        _array_data.header_contents
        ;
        # Detector: PILATUS 6M, S/N 60-0101
        # 2011-05-06T13:44:12.982
        # Pixel_size 172e-6 m x 172e-6 m
        # Exposure_time 0.9970000 s
        # Wavelength 0.9793 A
        # Detector_distance 0.30000 m
        # Beam_xy (1231.50, 1263.50) pixels
        # 2011-05-06T13:44:12.982
        ;

        _array_data.data
        ;
        $(Fabio.CBF_SECTION)
        Content-Type: application/octet-stream;
             conversions="x-CBF_BYTE_OFFSET"
        Content-Transfer-Encoding: BINARY
        X-Binary-Size: $(length(blob))
        X-Binary-ID: 1
        X-Binary-Element-Type: "signed 32-bit integer"
        X-Binary-Element-Byte-Order: LITTLE_ENDIAN
        X-Binary-Number-of-Elements: 4
        X-Binary-Size-Fastest-Dimension: 2
        X-Binary-Size-Second-Dimension: 2
        X-Binary-Size-Padding: 0

        """
        p = joinpath(TMP, "pilatus.cbf")
        Base.open(p, "w") do io
            write(io, codeunits(text))
            write(io, Fabio.CBF_STARTER)
            write(io, blob)
            write(io, codeunits("\n;\n\n"))
        end

        frame = Fabio.readimage(p)
        @test collect(frame) == A
        h = header(frame)
        @test h["Wavelength"] == "0.9793 A"
        @test getheader(h, "Exposure_time", Float64, -1.0) == -1.0   # "0.9970000 s" isn't a bare number
        @test h["Detector_distance"] == "0.30000 m"
        @test h["Beam_xy"] == "(1231.50, 1263.50) pixels"
        @test h["Detector"] == "PILATUS 6M, S/N 60-0101"
        @test h["Pixel_size"] == "172e-6 m x 172e-6 m"
        @test h["_array_data.header_convention"] == "PILATUS_1.2"
        # A lone token (the bare timestamp) has no value, so it is skipped rather than guessed at.
        @test !haskey(h, "2011-05-06T13:44:12.982")
    end

    @testset "uncompressed CBF" begin
        A = Int32[1 2; 3 4]
        p = joinpath(TMP, "raw.cbf")
        payload = encode(RawBlob(), A)
        text = """
        ###CBF: VERSION 1.5

        _array_data.data
        ;
        $(Fabio.CBF_SECTION)
        Content-Type: application/octet-stream;
             conversions="x-CBF_NONE"
        X-Binary-Size: $(length(payload))
        X-Binary-Element-Type: "signed 32-bit integer"
        X-Binary-Number-of-Elements: 4
        X-Binary-Size-Fastest-Dimension: 2
        X-Binary-Size-Second-Dimension: 2

        """
        Base.open(p, "w") do io
            write(io, codeunits(text))
            write(io, Fabio.CBF_STARTER)
            write(io, payload)
        end
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "inconsistent headers are caught" begin
        A = Int32[1 2; 3 4]
        p = joinpath(TMP, "bad.cbf")
        writecbf(p, A)
        txt = String(read(p))
        bad = replace(txt, "X-Binary-Number-of-Elements: 4" => "X-Binary-Number-of-Elements: 9")
        q = joinpath(TMP, "bad_elems.cbf")
        write(q, Vector{UInt8}(codeunits(bad)))
        @test_throws Fabio.CorruptFileError Fabio.openimage(q)

        nostart = joinpath(TMP, "nostarter.cbf")
        write(nostart, Vector{UInt8}(codeunits("###CBF: VERSION 1.5\n\nno binary here\n")))
        @test_throws Fabio.CorruptFileError Fabio.openimage(nostart)
    end
end

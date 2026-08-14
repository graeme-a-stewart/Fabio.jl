"""Concatenate several single-frame EDF blocks into one multi-frame file."""
function write_multiframe_edf(path, arrays; headers = nothing)
    Base.open(path, "w") do io
        for (i, A) in enumerate(arrays)
            h = headers === nothing ? Header() : headers[i]
            write(io, codeunits(edfheadertext(A, h)))
            write(io, encode(RawBlob(), A))
        end
    end
    return path
end

@testset "EDF" begin
    @testset "round-trip, every supported element type" begin
        for T in (Int8, UInt8, Int16, UInt16, Int32, UInt32, Float32, Float64)
            A = T <: AbstractFloat ? rand(T, 7, 5) : rand(T, 7, 5)
            p = joinpath(TMP, "rt_$T.edf")
            writeedf(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (7, 5)
            @test collect(frame) == A
        end
    end

    @testset "axis order: Dim_1 is the fast axis" begin
        A = UInt16[1 2 3; 4 5 6]        # size (2, 3): fast axis has 2 elements
        p = joinpath(TMP, "axes.edf")
        writeedf(p, A)
        h = Fabio.readheader(p)
        @test getheader(h, "Dim_1", Int) == 2
        @test getheader(h, "Dim_2", Int) == 3
        frame = Fabio.readimage(p)
        @test size(frame) == (2, 3)
        @test collect(frame) == A
        # rowmajor() reproduces numpy's / FabIO's (slow, fast) shape without copying.
        @test size(Fabio.rowmajor(frame)) == (3, 2)
        @test Fabio.rowmajor(frame)[3, 2] == A[2, 3]
    end

    @testset "header is parsed and preserved" begin
        extra = Header()
        extra["ESRFCurrent"] = "198.099"
        extra["Title"] = "a test frame"
        p = joinpath(TMP, "hdr.edf")
        writeedf(p, UInt16[1 2; 3 4], extra)
        h = Fabio.readheader(p)
        @test getheader(h, "ESRFCurrent", Float64) == 198.099
        @test h["Title"] == "a test frame"
        @test getheader(h, "DataType", String) == "UnsignedShort"
        @test getheader(h, "Size", Int) == 8
    end

    @testset "multi-frame files" begin
        arrays = [UInt16[i i+1; i+2 i+3] for i = 1:4]
        p = write_multiframe_edf(joinpath(TMP, "multi.edf"), arrays)
        Fabio.openimage(p) do file
            @test length(file) == 4
            @test Fabio.pixeltype(file) === UInt16
            for i = 1:4
                @test collect(file[i]) == arrays[i]
                @test file[i].fileindex == i
            end
            # AbstractVector interface
            @test length(collect(file)) == 4
            @test [maximum(f) for f in file] == [UInt16(i + 3) for i = 1:4]
            cube = framestack(file)
            @test size(cube) == (2, 2, 4)
            @test cube[:, :, 3] == arrays[3]
        end
    end

    @testset "read into a preallocated buffer" begin
        arrays = [UInt16[i i+1; i+2 i+3] for i = 1:3]
        p = write_multiframe_edf(joinpath(TMP, "prealloc.edf"), arrays)
        Fabio.openimage(p) do file
            dest = Matrix{UInt16}(undef, 2, 2)
            for i = 1:3
                readframe!(dest, file, i)
                @test dest == arrays[i]
            end
            @test_throws DimensionMismatch readframe!(zeros(UInt16, 3, 3), file, 1)
        end
    end

    @testset "headers only, no pixel read" begin
        arrays = [UInt16[i i; i i] for i = 1:3]
        p = write_multiframe_edf(joinpath(TMP, "hdrs.edf"), arrays)
        hs = Fabio.readheaders(p)
        @test length(hs) == 3
        @test all(h -> getheader(h, "Dim_1", Int) == 2, hs)
        @test framesize(p) == (2, 2)
        @test Fabio.pixeltype(p) === UInt16
    end

    @testset "explicit conversion is type stable" begin
        p = joinpath(TMP, "conv.edf")
        writeedf(p, UInt16[1 2; 3 4])
        frame = Fabio.readimage(p, Float32)
        @test eltype(frame) === Float32
        @test collect(frame) == Float32[1 2; 3 4]
        # The design's actual type-stability claim: `openimage` pays one dynamic dispatch to
        # learn the element type, and every frame read after that is inferred.
        Fabio.openimage(p) do file
            @test (@inferred ImageFrame{UInt16,2} file[1]) isa ImageFrame{UInt16,2}
        end
    end

    @testset "byte order is honoured" begin
        A = UInt16[0x0102 0x0304; 0x0506 0x0708]
        p = joinpath(TMP, "bigendian.edf")
        body = edfheadertext(A; byteorder = BigEndian())
        @test length(body) % 512 == 0
        Base.open(p, "w") do io
            write(io, codeunits(body))
            write(io, reinterpret(UInt8, vec(bswap.(A))))
        end
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "gzip is transparent" begin
        A = UInt16[10 20 30; 40 50 60]
        plain = joinpath(TMP, "plain.edf")
        writeedf(plain, A)
        gz = plain * ".gz"
        Base.open(gz, "w") do io
            write(io, transcode(GzipCompressor, read(plain)))
        end
        frame = Fabio.readimage(gz)
        @test collect(frame) == A
        @test eltype(frame) === UInt16
        # detection must see through the compression suffix
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), gz) === :EDF
    end

    @testset "zlib-compressed blobs" begin
        A = Int32[1 2 3; 4 5 6]
        p = joinpath(TMP, "zlibblob.edf")
        payload = encode(ZlibBlob(), A)
        h = "{\nByteOrder = LowByteFirst ;\nDataType = SignedInteger ;\n" *
            "Dim_1 = 2 ;\nDim_2 = 3 ;\nCompression = Zlib ;\nSize = $(length(payload)) ;\n"
        h = h * " "^mod(-(length(h) + 2), 512) * "}\n"
        Base.open(p, "w") do io
            write(io, codeunits(h))
            write(io, payload)
        end
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "truncated files" begin
        arrays = [UInt16[i i; i i] for i = 1:3]
        p = write_multiframe_edf(joinpath(TMP, "trunc.edf"), arrays)
        raw = read(p)
        cut = joinpath(TMP, "trunc_cut.edf")
        write(cut, raw[1:end-4])            # lose the tail of the last frame

        @test_throws Fabio.TruncatedFileError Fabio.openimage(cut)

        Fabio.openimage(cut; strict = false) do file
            @test Fabio.istruncated(file)
            @test length(file) == 2         # the two complete frames survive
            @test collect(file[1]) == arrays[1]
        end
    end

    @testset "mmap frames are views; readimage frames are owned" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "mmap.edf")
        writeedf(p, A)
        Fabio.openimage(p; mmap = true) do file
            f = file[1]
            @test collect(f) == A
            @test !(Fabio.data(f) isa Array)     # a reinterpreted view onto the mapping
        end
        @test Fabio.data(Fabio.readimage(p)) isa Array
    end
end

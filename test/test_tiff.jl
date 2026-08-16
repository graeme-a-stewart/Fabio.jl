using Fabio: writetiff, TiffStrips, readframe_layout

"""1-based index of the value field of `tag` in a little-endian TIFF's first IFD."""
function _find_tag_value_offset(raw::Vector{UInt8}, tag::Int)
    ifdoff = Int(reinterpret(UInt32, raw[5:8])[1])
    n = Int(reinterpret(UInt16, raw[(ifdoff+1):(ifdoff+2)])[1])
    for e = 0:(n-1)
        entry = ifdoff + 2 + 12 * e
        t = Int(reinterpret(UInt16, raw[(entry+1):(entry+2)])[1])
        t == tag && return entry + 8 + 1
    end
    error("tag $tag not found")
end

"""Corrupt the nfast/nslow words of a MarCCD header in place, to test the cross-check."""
function _break_marccd_dims(path, nfast, nslow)
    raw = read(path)
    put32(off, v) = (raw[(1024+off+1):(1024+off+4)] = reinterpret(UInt8, [htol(Int32(v))]))
    put32(80, nfast)
    put32(84, nslow)
    write(path, raw)
    return path
end

@testset "TIFF" begin
    @testset "round-trip, every supported element type" begin
        for T in (UInt8, Int8, UInt16, Int16, UInt32, Int32, Float32, Float64)
            A = T <: AbstractFloat ? rand(T, 9, 5) : rand(T(0):T(100), 9, 5)
            p = joinpath(TMP, "rt_$T.tif")
            writetiff(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (9, 5)
            @test collect(frame) == A
        end
    end

    @testset "axis order" begin
        A = UInt16[1 2 3 4; 5 6 7 8; 9 10 11 12]      # size (3, 4)
        p = joinpath(TMP, "axes.tif")
        writetiff(p, A)
        h = Fabio.readheader(p)
        @test h["ImageWidth"] == 3
        @test h["ImageLength"] == 4
        frame = Fabio.readimage(p)
        @test size(frame) == (3, 4)
        @test collect(frame) == A
        @test size(Fabio.rowmajor(frame)) == (4, 3)
    end

    @testset "big-endian files" begin
        A = UInt16[0x0102 0x0304; 0x0506 0x0708]
        p = joinpath(TMP, "be.tif")
        writetiff(p, A; bigendian = true)
        h = Fabio.readheader(p)
        @test h["ByteOrder"] == "HighByteFirst"
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "tier 1: a contiguous image memory-maps as a view" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "tier1.tif")
        writetiff(p, A)
        Fabio.openimage(p) do file
            @test file.frames[1].layout isa Fabio.BinaryLayout
            @test !(Fabio.data(file[1]) isa Array)      # zero-copy view onto the mapping
            @test collect(file[1]) == A
        end
    end

    @testset "tier 2: a multi-strip image is gathered" begin
        A = UInt16[10i + j for i = 1:6, j = 1:9]        # (6, 9), 9 rows
        p = joinpath(TMP, "strips.tif")
        writetiff(p, A; rowsperstrip = 2)               # 5 strips, written contiguously
        # Contiguous strips still qualify for tier 1 — that is the point of the check.
        Fabio.openimage(p) do file
            @test Fabio.readheader(p)["NumberOfStrips"] == 5
            @test file.frames[1].layout isa Fabio.BinaryLayout
            @test collect(file[1]) == A
        end

        # Now separate the strips so they are genuinely disjoint runs of bytes, which is
        # what a BinaryLayout cannot describe.
        gapped = joinpath(TMP, "strips_gapped.tif")
        writetiff(gapped, A; rowsperstrip = 2, stripgap = 8)
        Fabio.openimage(gapped) do file
            @test file.frames[1].layout isa TiffStrips     # fell through to tier 2
            @test Fabio.data(file[1]) isa Array            # gathered, so owned
            @test collect(file[1]) == A
        end
    end

    @testset "multi-frame TIFF" begin
        arrays = [UInt16[i i+1; i+2 i+3] for i = 1:3]
        p = joinpath(TMP, "multi.tif")
        writetiff(p, arrays)
        Fabio.openimage(p) do file
            @test length(file) == 3
            @test Fabio.pixeltype(file) === UInt16
            for i = 1:3
                @test collect(file[i]) == arrays[i]
                @test file[i].fileindex == i
            end
        end
    end

    @testset "Pilatus: text header in ImageDescription" begin
        desc = join(
            [
                "# Detector: PILATUS 6M, S/N 60-0101",
                "# Pixel_size 172e-6 m x 172e-6 m",
                "# Exposure_time 0.9970000 s",
                "# Wavelength 0.9793 A",
                "# Detector_distance 0.30000 m",
                "# N_excluded_pixels = 0",
                "# Flat_field: (nil)",
            ],
            "\r\n",
        ) * "\0"
        A = Int32[1 2; 3 4]
        p = joinpath(TMP, "pilatus.tif")
        writetiff(p, A; description = desc)

        fmt = Fabio.openimage(f -> Fabio.imageformat(f), p)
        @test fmt isa Fabio.TIFFLike{:pilatus}          # resolved by refine

        frame = Fabio.readimage(p)
        @test collect(frame) == A
        h = header(frame)
        @test h["Pixel_size"] == "172e-6 m x 172e-6 m"
        @test h["Exposure_time"] == "0.9970000 s"
        @test h["Wavelength"] == "0.9793 A"
        @test h["Detector"] == "PILATUS 6M, S/N 60-0101"
        @test h["Detector_distance"] == "0.30000 m"
        @test h["N_excluded_pixels"] == "0"            # split on '=' as well as whitespace
        @test h["Flat_field"] == "(nil)"               # …and on ':'
    end

    @testset "MarCCD: binary header at offset 1024" begin
        A = UInt16[10i + j for i = 1:8, j = 1:6]        # (8, 6) -> nfast 8, nslow 6
        p = joinpath(TMP, "frame.mccd")
        meta = Header()
        meta["xtal_to_detector"] = 150.0
        meta["beam_x"] = 1024.5
        meta["beam_y"] = 1020.25
        meta["exposure_time"] = 1.5
        meta["pixelsize_x"] = 0.079
        meta["source_wavelength"] = 0.9793
        Fabio.writemarccd(p, A, meta)

        fmt = Fabio.openimage(f -> Fabio.imageformat(f), p)
        @test fmt isa Fabio.TIFFLike{:marccd}

        frame = Fabio.readimage(p)
        @test collect(frame) == A
        h = header(frame)
        @test h["nfast"] == 8
        @test h["nslow"] == 6
        @test h["depth"] == 2
        @test h["xtal_to_detector"] ≈ 150.0             # stored as 150000, x1e-3 -> mm
        @test h["beam_x"] ≈ 1024.5
        @test h["exposure_time"] ≈ 1.5                  # stored as 1500 ms
        @test h["pixelsize_x"] ≈ 0.079                  # stored as 79000 nm -> mm
        @test h["source_wavelength"] ≈ 0.9793 atol = 1e-6
    end

    @testset "MarCCD: round-trips through writemarccd" begin
        A = UInt16[10i + j for i = 1:12, j = 1:9]
        meta = Header()
        meta["xtal_to_detector"] = 142.688
        meta["source_wavelength"] = 0.97625
        p = joinpath(TMP, "rt.mccd")
        Fabio.writemarccd(p, A, meta)
        frame = Fabio.readimage(p)
        @test collect(frame) == A
        @test size(frame) == (12, 9)
        h = header(frame)
        @test h["nfast"] == 12 && h["nslow"] == 9 && h["depth"] == 2
        @test h["xtal_to_detector"] ≈ 142.688
        @test h["source_wavelength"] ≈ 0.97625 atol = 1e-6
        # Writing back what we just read must be a fixed point.
        q = joinpath(TMP, "rt2.mccd")
        Fabio.writemarccd(q, collect(frame), h)
        @test read(p) == read(q)
    end

    @testset "MarCCD: coerce narrows to UInt16" begin
        out = coerce(Fabio.TIFFLike{:marccd}(), Int32[1 2; 3 4])
        @test eltype(out) === UInt16
        @test out == UInt16[1 2; 3 4]
    end

    @testset "MarCCD: mismatched dimensions warn rather than fail" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "badmarccd.mccd")
        Fabio.writemarccd(p, A)
        _break_marccd_dims(p, 999, 999)
        frame = @test_logs (:warn,) match_mode = :any Fabio.readimage(p)
        @test collect(frame) == A                       # pixels still read via the TIFF path
    end

    @testset "unsupported variants are refused clearly" begin
        A = UInt16[1 2; 3 4]
        p = joinpath(TMP, "comp.tif")
        writetiff(p, A)
        raw = read(p)
        # Flip the Compression tag from 1 (none) to 5 (LZW).
        i = _find_tag_value_offset(raw, Fabio.TIFF_COMPRESSION)
        raw[i] = 0x05
        q = joinpath(TMP, "lzw.tif")
        write(q, raw)
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(q)

        big = joinpath(TMP, "big.tif")
        write(big, vcat(UInt8[0x49, 0x49, 0x2B, 0x00], zeros(UInt8, 60)))
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(big)
    end
end

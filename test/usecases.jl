# ---------------------------------------------------------------------------------------
# DESIGN.md §16 as an executable acceptance suite.
#
# Every example the FabIO documentation gives, translated to Julia and then actually run.
# The point is not to test the readers again — the format testsets do that — but to check
# that the *shape* of the public API matches what the documented workflows need. If these all
# pass, someone following the FabIO docs can do the same things here.
#
# Numbering follows DESIGN.md. The cases that need work not yet done are marked, not quietly
# omitted, so the file says what is still missing.
# ---------------------------------------------------------------------------------------

using HDF5
using Printf: @sprintf

const UDIR = mktempdir()

"""Deterministic, position-dependent data, so a transposition cannot pass unnoticed."""
_upattern(::Type{T}, nx, ny, k = 0) where {T} =
    T[T(x + 61 * y + 1009 * k) for x = 1:nx, y = 1:ny]

@testset "use cases (DESIGN.md §16)" begin

    # -- 16.1 Open, inspect header, mean intensity ---------------------------------------
    @testset "16.1 open, inspect header, mean intensity" begin
        A = _upattern(UInt16, 20, 15)
        p = joinpath(UDIR, "image.tif")
        Fabio.writeimage(p, A)

        Fabio.openimage(p) do file
            frame = file[1]
            h = header(frame)
            @test h isa Header
            @test !isempty(h)
            # `display(header(frame))` in the docs; check it renders rather than printing it.
            @test !isempty(sprint(show, MIME"text/plain"(), h))
            # ImageFrame <: AbstractArray, so `mean` just works — the whole point of §4.
            @test mean(frame) == mean(A)
            @test frame isa AbstractArray{UInt16,2}
        end
    end

    # -- 16.2 Normalise to a header value and save ---------------------------------------
    @testset "16.2 normalise to a header value and save" begin
        A = _upattern(UInt16, 16, 12)
        h = Header()
        h["ESRFCurrent"] = "200.567"
        src = joinpath(UDIR, "exampleimage0001.edf")
        Fabio.writeimage(src, A; header = h)

        frame = Fabio.readimage(src)
        srcur = getheader(header(frame), "ESRFCurrent", Float64)
        @test srcur == 200.567
        normed = frame .* (200.0 / srcur)
        @test eltype(normed) === Float64

        out = joinpath(UDIR, "normed_0001.edf")
        Fabio.writeimage(out, normed)

        # DESIGN.md's claim about this example: the EDF writer records the wider type rather
        # than silently truncating. Checked on the file, not assumed.
        back = Fabio.readimage(out)
        @test eltype(back) === Float64
        @test getheader(header(back), "DataType", String) == "DoubleValue"
        @test collect(back) ≈ A .* (200.0 / srcur)
    end

    # -- 16.3 Convert TIFF to EDF --------------------------------------------------------
    @testset "16.3 convert TIFF to EDF" begin
        A = _upattern(UInt16, 18, 11)
        tif = joinpath(UDIR, "my.tiff")
        Fabio.writeimage(tif, A)

        Fabio.writeimage(
            joinpath(UDIR, "my.edf"),
            Fabio.convertimage(Fabio.readimage(tif), Fabio.EDF()),
        )
        back = Fabio.readimage(joinpath(UDIR, "my.edf"))
        @test collect(back) == A
        # The TIFF tags describing the source's storage do not follow it across.
        @test !haskey(header(back), "BitsPerSample")
        @test !haskey(header(back), "NumberOfStrips")
    end

    # -- 16.4 Display --------------------------------------------------------------------
    @testset "16.4 display conventions" begin
        # No plotting package is loaded here, so what is checked is the claim the plotting
        # advice rests on: which array axis is the fast detector axis in each view. A
        # deliberately non-square frame is the only way to see it.
        A = _upattern(UInt16, 30, 7)
        frame = ImageFrame(A)
        @test size(frame) == (30, 7)             # (fast, slow), what Makie's heatmap wants
        @test size(Fabio.rowmajor(frame)) == (7, 30)     # numpy/FabIO order
        @test size(Fabio.imageview(frame)) == (7, 30)    # (row, col), Images.jl and imshow
        # The views are views, not copies, and agree element by element.
        @test Fabio.rowmajor(frame)[3, 5] == frame[5, 3]
        @test parent(Fabio.rowmajor(frame)) === parent(frame)
    end

    # -- 16.5 File series, the documented mar2300 example ---------------------------------
    @testset "16.5 file series" begin
        # The documented example uses 200mMmgso4_001.mar2300 … from Zenodo 2546760. The
        # capability is what is checked here, on files the suite writes itself.
        for i = 1:8
            Fabio.writeimage(
                joinpath(UDIR, "200mMmgso4_" * lpad(i, 3, '0') * ".mar2300.edf"),
                _upattern(UInt16, 24, 20, i),
            )
        end
        series = Fabio.open_series(
            first = joinpath(UDIR, "200mMmgso4_001.mar2300.edf"),
        )
        try
            @test series[1][12, 10] == _upattern(UInt16, 24, 20, 1)[12, 10]
            # `im2 = im1.next(); im2.filename` in the Python.
            @test basename(series[2].source) == "200mMmgso4_002.mar2300.edf"
            # Unambiguously the 5th frame of the series, whatever the format's framing (§4.2).
            frame5 = series[5]
            @test collect(frame5) == _upattern(UInt16, 24, 20, 5)
            @test frame5.seriesindex == 5
            # The filename arithmetic FabIO exposes as next_filename/previous_filename.
            @test basename(Fabio.nextfile("200mMmgso4_001.mar2300")) == "200mMmgso4_002.mar2300"
            @test basename(Fabio.prevfile("200mMmgso4_002.mar2300")) == "200mMmgso4_001.mar2300"
            @test Fabio.jumpfile("200mMmgso4_001.mar2300", 5) == "200mMmgso4_005.mar2300"
        finally
            close(series)
        end
    end

    # -- 16.6 Random access across a series ----------------------------------------------
    @testset "16.6 random access across a series" begin
        for i = 0:99
            Fabio.writeimage(
                joinpath(UDIR, "foobar_" * lpad(i, 4, '0') * ".edf"),
                _upattern(UInt32, 6, 4, i),
            )
        end
        Fabio.open_series(first = joinpath(UDIR, "foobar_0000.edf")) do series
            @test length(series) == 100
            # The documented example takes frames 1, 100 and 19, in that order.
            frame1, frame100, frame19 = series[1], series[100], series[19]
            @test collect(frame1) == _upattern(UInt32, 6, 4, 0)     # foobar_0000 is frame 1
            @test collect(frame100) == _upattern(UInt32, 6, 4, 99)
            @test collect(frame19) == _upattern(UInt32, 6, 4, 18)
            # Frames taken before the series moved on are still valid afterwards.
            @test collect(frame1) == _upattern(UInt32, 6, 4, 0)
        end
    end

    # -- 16.7 Sequential access with full frame provenance --------------------------------
    @testset "16.7 sequential access with frame provenance" begin
        Fabio.open_series(
            first = joinpath(UDIR, "200mMmgso4_001.mar2300.edf");
            count = 4,
        ) do series
            seen = 0
            for frame in series
                seen += 1
                @test frame isa AbstractArray            # the data: it *is* an array
                @test header(frame) isa Header
                @test frame.seriesindex == seen          # index within the series
                @test frame.fileindex == 1               # index within its source file
                @test frame.source !== nothing           # the file it came from
                @test collect(frame) == _upattern(UInt16, 24, 20, seen)
            end
            @test seen == 4
        end

        # The same provenance holds within a single multi-frame file.
        A = _upattern(UInt16, 8, 6)
        p = joinpath(UDIR, "prov.mrc")
        Fabio.writeimage(p, [A, A .+ 0x0001, A .+ 0x0002])
        Fabio.openimage(p) do file
            for (i, frame) in enumerate(file)
                @test frame.fileindex == i
                @test frame.seriesindex == i
                @test frame.source == p
            end
        end
    end

    # -- 16.8 Bulk convert a directory, CBF → EDF ----------------------------------------
    @testset "16.8 bulk convert a directory, CBF to EDF" begin
        srcdir = joinpath(UDIR, "cbfs")
        dstdir = joinpath(UDIR, "edfs")
        mkpath(srcdir)
        originals = Dict{String,Matrix{Int32}}()
        for i = 1:6
            A = _upattern(Int32, 12, 9, i)
            f = joinpath(srcdir, @sprintf("frame_%03d.cbf", i))
            Fabio.writeimage(f, A)
            originals[basename(f)] = A
        end

        files = sort(filter(endswith(".cbf"), readdir(srcdir; join = true)))
        @test length(files) == 6
        mkpath(dstdir)
        # mmap sources are read-only and immutable, so this is safe to run in parallel (§13).
        Threads.@threads for f in files
            dst = joinpath(dstdir, first(splitext(basename(f))) * ".edf")
            Fabio.writeimage(dst, Fabio.convertimage(Fabio.readimage(f), Fabio.EDF()))
        end

        @test length(readdir(dstdir)) == 6
        for (name, A) in originals
            out = joinpath(dstdir, first(splitext(name)) * ".edf")
            @test isfile(out)
            @test collect(Fabio.readimage(out)) == A
        end
    end

    # -- 16.9 HDF5 → per-frame CBF -------------------------------------------------------
    @testset "16.9 HDF5 to per-frame CBF" begin
        master = joinpath(UDIR, "collect_01_00001_master.h5")
        h5open(master, "w") do h
            create_group(create_group(h, "entry"), "data")["data"] =
                cat((_upattern(Int32, 10, 8, k) for k = 1:4)...; dims = 3)
        end

        detectorheader = Header()
        detectorheader["Detector"] = "Eiger"

        Fabio.openimage(master) do images
            @test length(images) == 4
            for (i, frame) in enumerate(images)
                Fabio.writeimage(
                    joinpath(UDIR, @sprintf("collect_01_00001_%04d.cbf", i)),
                    ImageFrame(parent(frame), detectorheader);
                    format = Fabio.CBF(),
                )
            end
        end

        for i = 1:4
            out = joinpath(UDIR, @sprintf("collect_01_00001_%04d.cbf", i))
            @test isfile(out)
            back = Fabio.readimage(out)
            @test collect(back) == _upattern(Int32, 10, 8, i)
            @test Fabio.getci(header(back), "Detector") == "Eiger"
        end
    end

    # -- 16.10 HDF5 → multi-frame TIFF, then compare frame statistics --------------------
    @testset "16.10 HDF5 to multi-frame TIFF, comparing statistics" begin
        water = joinpath(UDIR, "sample_water0000.h5")
        h5open(water, "w") do h
            create_group(create_group(h, "entry"), "data")["data"] =
                cat((_upattern(Int32, 14, 9, k) for k = 1:5)...; dims = 3)
        end

        tiff = joinpath(UDIR, "sample_water0000.tiff")
        src = Fabio.openimage(water)
        try
            Fabio.writeimage(tiff, collect(src))          # multi-frame writer
            dst = Fabio.openimage(tiff)
            try
                @test length(dst) == length(src)
                for i = 1:length(src)
                    a, b = src[i], dst[i]
                    @test a == b                          # the tutorial's final check
                    @test minimum(a) == minimum(b)
                    @test maximum(a) == maximum(b)
                    @test mean(a) == mean(b)
                    @test std(a) ≈ std(b)
                end
            finally
                close(dst)
            end
        finally
            close(src)
        end
    end

    # -- 16.11 Command-line tools --------------------------------------------------------
    @testset "16.11 command-line tools" begin
        # `Fabio.main()` and a fabio-convert equivalent are Phase 4 item 6.
        @test_skip Fabio.main(["--list"]) == 0
    end
end

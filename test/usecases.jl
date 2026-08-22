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

    # -- 16.5–16.7 File series -----------------------------------------------------------
    @testset "16.5–16.7 file series" begin
        # `open_series`, `nextfile`/`prevfile`/`jumpfile` and per-frame series provenance are
        # Phase 4 item 3 and are not built yet. These are the assertions they must satisfy.
        @test_skip Fabio.open_series(first = joinpath(UDIR, "series_0001.edf")) !== nothing
        @test_skip Fabio.nextfile("200mMmgso4_001.mar2300") == "200mMmgso4_002.mar2300"
        # 16.7's frame provenance already exists on a single file, so it is checked here.
        A = _upattern(UInt16, 8, 6)
        p = joinpath(UDIR, "prov.mrc")
        Fabio.writeimage(p, [A, A .+ 0x0001, A .+ 0x0002])
        Fabio.openimage(p) do file
            for (i, frame) in enumerate(file)
                @test frame.fileindex == i        # index within its source file
                @test frame.seriesindex == i      # index within the enclosing series
                @test frame.source == p           # the file it came from
                @test header(frame) isa Header
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

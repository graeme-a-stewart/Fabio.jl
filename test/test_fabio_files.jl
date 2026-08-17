# Real detector files from FabIO's test collection. The three small ones are committed
# (see test/data/fabio/PROVENANCE.md); the rest are opt-in:
#
#   FABIO_JL_FABIOTEST=/path/to/downloaded/testimages \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values are the Python FabIO's, reading the same files.

const FABIODIR = joinpath(@__DIR__, "data", "fabio")

@testset "committed FabIO test files" begin
    @testset "fit2d.f2d is little-endian" begin
        # The reader was written with no real file to check against, and its byte order could
        # not be settled from FabIO's source, which decodes i/r arrays natively while decoding
        # l masks big-endian in the same function. This file settles it: big-endian yields
        # denormals, little-endian matches FabIO exactly.
        p = joinpath(FABIODIR, "fit2d.f2d")
        frame = Fabio.readimage(p)
        @test eltype(frame) === Float32
        @test size(frame) == (25, 28)
        @test Float64(minimum(frame)) ≈ 455.0
        @test Float64(maximum(frame)) ≈ 1793.0
        @test sum(Float64.(frame)) ≈ 505548.0

        wrong = Fabio.openimage(f -> f[1], p; format = Fabio.Fit2D{:big}())
        @test Float64(maximum(wrong)) < 1e-30      # denormal rubbish, as expected
    end

    @testset "Fit2D masks" begin
        # 123 x 456: neither square nor a whole number of 32-bit words wide, so the row
        # padding has to be right or the mask shears.
        face = Fabio.readimage(joinpath(FABIODIR, "face.msk"))
        @test eltype(face) === UInt8
        @test size(face) == (123, 456)
        @test minimum(face) == 0
        @test maximum(face) == 1
        @test sum(Int.(face)) == 10034      # FabIO's value for this file

        click = Fabio.readimage(joinpath(FABIODIR, "fit2d_click.msk"))
        @test size(click) == (1024, 1024)
        @test sum(Int.(click)) == 96         # FabIO's value for this file
    end
end

# ---------------------------------------------------------------------------------------
# The larger files, if they have been downloaded.
# ---------------------------------------------------------------------------------------

const FABIOTEST = get(ENV, "FABIO_JL_FABIOTEST", "")

if !isempty(FABIOTEST) && isdir(FABIOTEST)
    # name => (format, fast, slow, eltype, nframes, min, max, sum)
    # Generated from FabIO reading these files, not written by hand. The only value
    # not FabIO's is v3_2frames.spe's frame count: FabIO reports 1 where its own
    # header says 2, since SpeImage never sets _nframes.
    cases = [
    ("mgzn-20hpt.img", Raxis, 2300, 1280, UInt32, 1, 16.0, 15040.0, 847356402.0),
    ("b191_1_9_1.img", OXD, 512, 512, Int32, 1, -500.0, 11975.0, 6737309.0),
    ("b191_1_9_1_uncompressed.img", OXD, 512, 512, Int32, 1, -500.0, 11975.0, 6737309.0),
    # TY5. FabIO returns Float64 here only because dec_TY5 allocates with numpy.zeros and
    # never casts; the counts are integers, so Int32 is what this reader gives. The values
    # agree exactly.
    ("100nmfilmonglass_1_1.real.img", OXD, 1024, 1024, Int32, 1, -172.0, 460.0, 46351476.0),
    ("d80_60s.img", OXD, 2048, 2048, Int32, 1, 0.0, 73248.0, 107825806328.0),
    ("ref_d20x_310mm.dm3", DM3, 2048, 2048, Float32, 1, -31842.353515625, 23461.671875, 2388184839.5905056),
    ("v3.spe", SPE, 1024, 100, UInt16, 1, 0.0, 877.0, 82876242.0),
    ("v3_2frames.spe", SPE, 1024, 255, Float32, 2, -42.0, 47.0, 44495.0),
    ("v3_custom_roi.spe", SPE, 500, 50, UInt16, 1, 0.0, 889.0, 20542901.0),
    ("Pilatus1M.f2d", Fabio.Fit2D, 981, 1043, Float32, 1, -2.0, 260209.0, 463947050.0),
    ("mpa_test.mpa", MPA, 1024, 1024, Float64, 1, 0.0, 1295.0, 900731.0),
    ]

    @testset "downloaded FabIO test files" begin
        for (name, F, fast, slow, T, nfr, mn, mx, sm) in cases
            p = joinpath(FABIOTEST, name)
            if !isfile(p)
                @info "$name not downloaded; skipping"
                continue
            end
            @testset "$name" begin
                file = Fabio.openimage(p)
                try
                    @test Fabio.imageformat(file) isa F
                    @test length(file) == nfr
                    frame = file[1]
                    @test eltype(frame) === T
                    @test size(frame) == (fast, slow)
                    @test Float64(minimum(frame)) ≈ mn rtol = 1e-6
                    @test Float64(maximum(frame)) ≈ mx rtol = 1e-6
                    @test sum(Float64.(frame)) ≈ sm rtol = 1e-6
                finally
                    close(file)
                end
            end
        end

        @testset "OXD TY5 is exercised, but not its row reset" begin
            # 100nmfilmonglass_1_1 is the only TY5 file to hand and it is 1024 square, so it
            # cannot separate this reader's per-NX row reset from FabIO's per-NY one — both
            # give the same answer when the two dimensions are equal. A non-square TY5 file
            # would settle that; until then the fixture test is the only evidence.
            p = joinpath(FABIOTEST, "100nmfilmonglass_1_1.real.img")
            if isfile(p)
                h = Fabio.readheader(p)
                @test h["Compression"] == "TY5"
                @test h["NX"] == h["NY"]        # square, hence not discriminating
            end
        end

        @testset "OXD: the TY1 codec against its uncompressed twin" begin
            # The archive holds the same image both ways, which checks the codec against
            # ground truth rather than against a statistic.
            a = joinpath(FABIOTEST, "b191_1_9_1.img")
            b = joinpath(FABIOTEST, "b191_1_9_1_uncompressed.img")
            if isfile(a) && isfile(b)
                @test collect(Fabio.readimage(a)) == collect(Fabio.readimage(b))
            else
                @info "the OXD pair is not downloaded; skipping"
            end
        end

        @testset "SPE: both frames of a two-frame file" begin
            p = joinpath(FABIOTEST, "v3_2frames.spe")
            if isfile(p)
                file = Fabio.openimage(p)
                try
                    # FabIO reports nframes = 1 here while its own header says 2, since
                    # SpeImage never sets _nframes. Both frames are present.
                    @test length(file) == 2
                    @test sum(Float64.(file[1])) ≈ 44495.0
                    @test sum(Float64.(file[2])) ≈ 61011.0
                finally
                    close(file)
                end
            end
        end
    end
else
    @info "Skipping the downloaded FabIO test files; set FABIO_JL_FABIOTEST to enable them"
end

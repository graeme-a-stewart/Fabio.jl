# ---------------------------------------------------------------------------------------
# Real MRC files from the EMDB. Opt-in, since they are large and not redistributable here.
#
#   FABIO_JL_MRC_TESTDATA=/path/to/MRC_data \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Pixel reference values come from the Python FabIO, read one frame at a time through
# `fabio.open(path, frame=n)`. Its `get_frame`/`getframe` cannot be used on MRC in 2026.6.0:
# both copy the deprecated `dim1` attribute onto a frame whose `data` is still None, and the
# setter tries to reshape it. Two of the ten files defeat FabIO entirely, with a
# UnicodeDecodeError raised while decoding the 80-character label block as strict UTF-8.
#
# The header assertions are the interesting ones. This reader follows MRC2014, where several
# words are Float32 and the "MAP " stamp is word 53, against FabIO reading every word as Int32
# and naming only the first thirty. `DMIN`, `DMAX` and `DMEAN` are stored statistics of the
# pixel data, so comparing them against the data itself decides which reading is right.
# ---------------------------------------------------------------------------------------

const MRC_DATA = get(ENV, "FABIO_JL_MRC_TESTDATA", "")

if !isempty(MRC_DATA) && isdir(MRC_DATA)
    mrc_files = sort(filter(f -> endswith(f, ".mrc"), readdir(MRC_DATA; join = true)))

    if isempty(mrc_files)
        @info "FABIO_JL_MRC_TESTDATA has no .mrc files; skipping"
    else
        # file => (nframes, fast, slow, [(frame, min, max, sum), …]) with FabIO's values,
        # frame numbers 0-based as FabIO reports them.
        refs = Dict(
            "stack1.mrc" => (50, 128, 128, [
                (0, -27.03693008, 28.27557182, 19524.94642),
                (25, -37.05858612, 50.81641388, -7221.313383),
                (49, -33.84173203, 26.03326607, -8125.134599)]),
            "Bgal_tilt_stk.mrc" => (119, 100, 100, [
                (0, 1323.777954, 2488.222412, 18267937.07),
                (59, 1391.777832, 2706.000244, 19488824.74)]),
            "groel_stagg_map1.mrc" => (155, 155, 155, [
                (0, -0.001376046566, -0.0005349706626, -12.85351124),
                (77, -0.09552527964, 0.083366476, 38.17672533)]),
        )

        @testset "MRC: real EMDB files" begin
            @testset "pixel data matches FabIO" begin
                for (name, (nfr, fast, slow, frames)) in refs
                    p = joinpath(MRC_DATA, name)
                    if !isfile(p)
                        @info "$name not present; skipping"
                        continue
                    end
                    file = Fabio.openimage(p)
                    try
                        @test Fabio.imageformat(file) isa MRC
                        @test length(file) == nfr
                        @test Fabio.pixeltype(file) === Float32
                        for (i, mn, mx, s) in frames
                            d = collect(file[i+1])       # FabIO counts frames from 0
                            @test size(d) == (fast, slow)
                            @test Float64(minimum(d)) ≈ mn rtol = 1e-9
                            @test Float64(maximum(d)) ≈ mx rtol = 1e-9
                            @test sum(Float64.(d)) ≈ s rtol = 1e-9
                        end
                    finally
                        close(file)
                    end
                end
            end

            @testset "the MAP stamp is at word 53" begin
                # FabIO places MAP at word 27 and checks it reads back as "MAP ", which on a
                # real file it never does — it logs at info level and carries on.
                for p in mrc_files
                    h = Fabio.readheader(p)
                    @test h["MAP"] == "MAP "
                end
            end

            @testset "the Float32 header words agree with the pixel data" begin
                # DMIN, DMAX and DMEAN are the stored statistics of the data. They can only
                # match if words 20-22 really are Float32, so this decides the question
                # against FabIO's Int32 reading of the same words.
                for p in mrc_files
                    file = Fabio.openimage(p)
                    try
                        h = header(file[1])
                        lo, hi, tot, n = Inf, -Inf, 0.0, 0
                        for i = 1:length(file)
                            d = collect(file[i])
                            lo = min(lo, Float64(minimum(d)))
                            hi = max(hi, Float64(maximum(d)))
                            tot += sum(Float64.(d))
                            n += length(d)
                        end
                        @test h["DMIN"] ≈ lo rtol = 1e-6
                        @test h["DMAX"] ≈ hi rtol = 1e-6
                        @test h["DMEAN"] ≈ tot / n atol = 1e-5 * max(1.0, abs(hi))
                        # Cell angles are Float32 too, and orthogonal cells are the norm.
                        @test h["CELL_ALPHA"] ≈ 90.0
                        @test h["CELL_BETA"] ≈ 90.0
                        @test h["CELL_GAMMA"] ≈ 90.0
                    finally
                        close(file)
                    end
                end
            end

            @testset "labels that are not valid UTF-8 do not stop the read" begin
                # cav6216_stk.mrc and cav6217_stk.mrc carry a 0xaf byte in the label block.
                # FabIO decodes labels as strict UTF-8 and raises; bytes are mapped to
                # codepoints here instead, so the file still reads.
                for name in ("cav6216_stk.mrc", "cav6217_stk.mrc")
                    p = joinpath(MRC_DATA, name)
                    isfile(p) || continue
                    file = Fabio.openimage(p)
                    try
                        @test length(file) == 45
                        @test size(file[1]) == (128, 128)
                        @test Fabio.pixeltype(file) === Float32
                        @test haskey(header(file[1]), "LABEL_00")
                    finally
                        close(file)
                    end
                end
            end

            @testset "every file in the set reads" begin
                for p in mrc_files
                    file = Fabio.openimage(p)
                    try
                        @test length(file) >= 1
                        h = header(file[1])
                        @test size(file[1]) == (h["NX"], h["NY"])
                        @test length(file) == h["NZ"]
                        @test h["MODE"] == 2                 # Float32, as EMDB writes
                    finally
                        close(file)
                    end
                end
            end
        end
    end
else
    @info "Skipping the real MRC tests; set FABIO_JL_MRC_TESTDATA to enable them"
end

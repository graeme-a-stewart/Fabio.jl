# ---------------------------------------------------------------------------------------
# Real Nonius KappaCCD files. Opt-in, since they are not redistributable here.
#
#   FABIO_JL_KCD_TESTDATA=/path/to/kcd/files \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values come from the Python FabIO reading the same files.
# ---------------------------------------------------------------------------------------

const KCD_DATA = get(ENV, "FABIO_JL_KCD_TESTDATA", "")

if !isempty(KCD_DATA) && isdir(KCD_DATA)
    kcd_files = sort(filter(f -> endswith(f, ".kcd"), readdir(KCD_DATA; join = true)))

    if isempty(kcd_files)
        @info "FABIO_JL_KCD_TESTDATA has no .kcd files; skipping"
    else
        @testset "KCD: real KappaCCD files" begin
            ref = filter(p -> endswith(p, "s01f0016.kcd"), kcd_files)

            if !isempty(ref)
                @testset "frame matches FabIO" begin
                    file = Fabio.openimage(first(ref))
                    @test Fabio.imageformat(file) isa KCD
                    @test length(file) == 1              # two readouts, one image
                    frame = file[1]
                    @test eltype(frame) === Int32
                    @test size(frame) == (625, 576)      # FabIO reports (576, 625)
                    @test minimum(frame) == 0
                    @test maximum(frame) == 14230
                    @test sum(Int64.(frame)) == 90446545
                    close(file)
                end

                @testset "the whole header survives the bare 'Binned mode' line" begin
                    # That line is the only header line without an '='. Treating it as the
                    # end of the header stops the parse there and loses everything below,
                    # which on these files is two thirds of it: 11 entries instead of 35.
                    h = Fabio.readheader(first(ref))
                    @test length(h) == 35
                    @test h["Mode"] == "Binned"
                    # Keys before the bare line …
                    @test getheader(h, "X dimension", Int) == 625
                    @test getheader(h, "Y dimension", Int) == 576
                    @test getheader(h, "Number of readouts", Int) == 2
                    @test getheader(h, "Exposure time", Float64) ≈ 3.747
                    # … and keys after it, which are the ones a premature stop would drop.
                    @test getheader(h, "Alpha1", Float64) ≈ 0.7093
                    @test getheader(h, "Alpha2", Float64) ≈ 0.71359
                    @test h["Target material"] == "MO"
                    @test h["Polarisation direction"] == "PARALLEL"
                    @test getheader(h, "Kappa-support angle", Float64) ≈ 50.00396
                    @test getheader(h, "pixel X-size (um)", Float64) ≈ 55.0
                    @test h["Data type"] == "u16"
                end
            else
                @info "s01f0016.kcd not present; skipping the reference checks"
            end

            @testset "every file reads consistently" begin
                for p in kcd_files
                    file = Fabio.openimage(p)
                    try
                        @test Fabio.imageformat(file) isa KCD
                        @test Fabio.pixeltype(file) === Int32
                        @test length(file) == 1
                        frame = file[1]
                        h = header(frame)
                        @test size(frame) ==
                              (getheader(h, "X dimension", Int), getheader(h, "Y dimension", Int))
                        # A premature end-of-header would leave far fewer keys than this.
                        @test length(h) >= 30
                        @test minimum(frame) >= 0
                    finally
                        close(file)
                    end
                end
            end
        end
    end
else
    @info "Skipping the real KCD tests; set FABIO_JL_KCD_TESTDATA to enable them"
end

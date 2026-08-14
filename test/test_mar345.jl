# ---------------------------------------------------------------------------------------
# Real mar345 data. Opt-in, because the files are large and not redistributable here.
# They are the dataset the FabIO documentation uses for its file-series example:
# Zenodo 10.5281/zenodo.2546760, `200mMmgso4_%03d.mar2300`.
#
#   FABIO_JL_MAR345_TESTDATA=/path/to/dir julia --project -e 'using Pkg; Pkg.test()'
# ---------------------------------------------------------------------------------------

const MAR_DATA = get(ENV, "FABIO_JL_MAR345_TESTDATA", "")

if !isempty(MAR_DATA) && isdir(MAR_DATA)
    files = sort(filter(f -> endswith(f, ".mar2300"), readdir(MAR_DATA; join = true)))

    if isempty(files)
        @info "FABIO_JL_MAR345_TESTDATA has no .mar2300 files; skipping"
    else
        @testset "mar345: real image-plate files" begin
            ref = first(filter(f -> endswith(f, "200mMmgso4_001.mar2300"), files))

            @testset "reference frame matches FabIO" begin
                frame = Fabio.readimage(ref)
                @test eltype(frame) === UInt32
                @test size(frame) == (2300, 2300)
                @test minimum(frame) == 0
                @test maximum(frame) == 18633
                @test sum(UInt64.(frame)) == 202056553
                @test mean(frame) ≈ 38.195946 atol = 1e-5
                @test std(frame; corrected = false) ≈ 54.695621 atol = 1e-4
                # FabIO reports d[1150, 1150:1156] in numpy (slow, fast) order.
                @test collect(frame[1151:1156, 1151]) == UInt32[320, 187, 113, 96, 75, 58]
            end

            @testset "header" begin
                h = Fabio.readheader(ref)
                @test h["Format"] == "compressed"
                @test h["Mode"] == "Time"
                @test getheader(h, "NumPixels", Int) == 5_290_000
                @test getheader(h, "Wavelength", Float64) ≈ 1.54179
                @test getheader(h, "Distance", Float64) ≈ 175.0
                @test getheader(h, "PixelLength", Float64) ≈ 0.15
                @test getheader(h, "NumHigh", Int) == 0
                @test h["ByteOrder"] in ("LowByteFirst", "HighByteFirst")
            end

            @testset "the whole series reads" begin
                for f in files
                    frame = Fabio.readimage(f)
                    @test size(frame) == (2300, 2300)
                    @test eltype(frame) === UInt32
                    @test minimum(frame) == 0
                end
            end
        end
    end
else
    @info "Skipping the real mar345 tests; set FABIO_JL_MAR345_TESTDATA to enable them"
end

# ---------------------------------------------------------------------------------------
# Real Pilatus files. Opt-in, since they are not redistributable here.
#
#   FABIO_JL_PILATUS_TESTDATA=/path/to/calibration_data \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values come from the Python FabIO reading the same files. Two detectors are
# covered: a 981x1043 PILATUS 1M (`agbe_*`, `water1_*`, `vac3_*`, `glassy_carbon2_*`) and a
# 487x195 PILATUS 100K (`extra/`).
# ---------------------------------------------------------------------------------------

const PILATUS_DATA = get(ENV, "FABIO_JL_PILATUS_TESTDATA", "")

if !isempty(PILATUS_DATA) && isdir(PILATUS_DATA)
    @testset "Pilatus: real detector files" begin
        agbe = joinpath(PILATUS_DATA, "agbe_008_0001.tif")
        small = joinpath(PILATUS_DATA, "extra", "AgBeh_A1_43_001_0000.tiff")

        if isfile(agbe)
            @testset "1M frame matches FabIO" begin
                file = Fabio.openimage(agbe)
                @test Fabio.imageformat(file) isa Fabio.TIFFLike{:pilatus}
                @test length(file) == 1
                frame = file[1]
                @test eltype(frame) === Int32
                @test size(frame) == (981, 1043)          # FabIO reports (1043, 981)
                @test minimum(frame) == -2                # a real Pilatus records negatives
                @test maximum(frame) == 1293289
                @test sum(Int64.(frame)) == 1769753086
                @test mean(frame) ≈ 1729.654506 atol = 1e-5
                @test std(frame; corrected = false) ≈ 35042.328974 atol = 1e-4
                # FabIO's d[0, :5] and d[600, 600:605], in its (slow, fast) order.
                @test collect(frame[1:5, 1]) == Int32[2, -2, 2, 1, 3]
                @test collect(frame[601:605, 601]) == Int32[12, 9, 8, 2, 9]
                close(file)
            end

            @testset "header matches FabIO" begin
                h = Fabio.readheader(agbe)
                @test h["Pixel_size"] == "172e-6 m x 172e-6 m"
                @test h["Silicon"] == "sensor, thickness 0.000450 m"
                @test h["Exposure_time"] == "0.5000000 s"
                @test h["Exposure_period"] == "1.0000000 s"
                @test h["Count_cutoff"] == "1279546 counts"
                @test h["Threshold_setting"] == "6000 eV"
                @test h["Gain_setting"] == "autog (vrf = 1.000)"
                @test h["N_excluded_pixels"] == "35"
                @test h["Excluded_pixels"] == "badpix_mask.tif"
                @test h["Flat_field"] == "FF_p10-0130_E12000_T6000_vrf_m0p100.tif"
                @test h["Trim_file"] == "p10-0130_E12000_T6000.bin"
                # The TIFF tags are exposed alongside the Pilatus text header.
                @test h["ImageWidth"] == 981
                @test h["ImageLength"] == 1043
                @test h["BitsPerSample"] == 32
            end
        else
            @info "agbe_008_0001.tif not present; skipping the 1M reference checks"
        end

        if isfile(small)
            @testset "100K frame matches FabIO" begin
                frame = Fabio.readimage(small)
                @test eltype(frame) === Int32
                @test size(frame) == (487, 195)           # FabIO reports (195, 487)
                @test minimum(frame) == -2
                @test maximum(frame) == 1372057
                @test sum(Int64.(frame)) == 202199242
                @test mean(frame) ≈ 2129.197515 atol = 1e-5
                @test collect(frame[1:5, 1]) == Int32[12, 9, 11, 11, 10]
                h = header(frame)
                @test h["Silicon"] == "sensor, thickness 0.000320 m"
                @test h["Gain_setting"] == "mid gain (vrf = -0.200)"
                @test h["Flat_field"] == "(nil)"
            end
        else
            @info "extra/AgBeh_A1_43_001_0000.tiff not present; skipping the 100K checks"
        end

        @testset "every file in the tree reads as Pilatus" begin
            files = String[]
            for (root, _, names) in walkdir(PILATUS_DATA), n in names
                (endswith(n, ".tif") || endswith(n, ".tiff")) && push!(files, joinpath(root, n))
            end
            @test !isempty(files)
            for p in files
                file = Fabio.openimage(p)
                try
                    @test Fabio.imageformat(file) isa Fabio.TIFFLike{:pilatus}
                    @test Fabio.pixeltype(file) === Int32
                    @test length(file) == 1
                    frame = file[1]
                    @test ndims(frame) == 2
                    @test all(>(0), size(frame))
                    # Pilatus marks dead pixels -2 and gaps -1, so negatives are expected;
                    # anything below -2 would mean the data was misread.
                    @test minimum(frame) >= -2
                    @test haskey(header(frame), "Pixel_size")
                finally
                    close(file)
                end
            end
        end
    end
else
    @info "Skipping the real Pilatus tests; set FABIO_JL_PILATUS_TESTDATA to enable them"
end

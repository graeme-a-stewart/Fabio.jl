# ---------------------------------------------------------------------------------------
# Real MarCCD files. Opt-in, since they are large and not redistributable here.
#
#   FABIO_JL_MARCCD_TESTDATA=/path/to/mccd_data \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values come from the Python FabIO. Note that FabIO's own `fabio.open` does *not*
# expose the MarCCD binary header: `TifImage.read` calls `MarccdImage._readheader`, which
# parses the 3072-byte struct into `self.header`, and then `_read_with_tiffio` overwrites
# `self.header` with the TIFF metadata. The header field values below were therefore obtained
# by calling FabIO's `marccdimage.interpret_header` directly, which is its authoritative
# struct definition, generated from the vendor's C header.
# ---------------------------------------------------------------------------------------

const MARCCD_DATA = get(ENV, "FABIO_JL_MARCCD_TESTDATA", "")

if !isempty(MARCCD_DATA) && isdir(MARCCD_DATA)
    marccd_files = sort(filter(f -> endswith(f, ".mccd"), readdir(MARCCD_DATA; join = true)))

    if isempty(marccd_files)
        @info "FABIO_JL_MARCCD_TESTDATA has no .mccd files; skipping"
    else
        @testset "MarCCD: real detector files" begin
            ref = first(filter(f -> endswith(f, "ntds11X5C3G3_2_0001.mccd"), marccd_files))

            @testset "frame matches FabIO" begin
                file = Fabio.openimage(ref)
                @test Fabio.imageformat(file) isa Fabio.TIFFLike{:marccd}
                @test length(file) == 1
                frame = file[1]
                @test eltype(frame) === UInt16
                @test size(frame) == (3072, 3072)
                @test minimum(frame) == 0
                @test maximum(frame) == 65535
                @test sum(Int64.(frame)) == 993076043
                @test mean(frame) ≈ 105.2301240497 atol = 1e-8
                @test collect(frame[1:5, 1]) == UInt16[0, 0, 0, 0, 0]
                @test !(Fabio.data(frame) isa Array)     # zero-copy mmap view
                close(file)
            end

            @testset "binary header fields match FabIO's struct parse" begin
                # Stored integers, as FabIO's interpret_header reports them, divided by the
                # scale this reader applies to reach physical units.
                h = Fabio.readheader(ref)
                @test h["nfast"] == 3072
                @test h["nslow"] == 3072
                @test h["depth"] == 2
                @test h["data_type"] == 0
                @test h["origin"] == 0
                @test h["orientation"] == 0
                @test h["over_8_bits"] == 0
                @test h["over_16_bits"] == 0
                @test h["xtal_to_detector"] ≈ 142.688          # stored 142688
                @test h["beam_x"] ≈ 112.079                    # stored 112079
                @test h["beam_y"] ≈ 113.571                    # stored 113571
                @test h["integration_time"] ≈ 7.0              # stored 7000
                @test h["exposure_time"] ≈ 5.0                 # stored 5000
                @test h["readout_time"] ≈ 1.158                # stored 1158
                @test h["detector_type"] == 0
                @test h["pixelsize_x"] ≈ 0.073242              # stored 73242 nm
                @test h["pixelsize_y"] ≈ 0.073242
                @test h["source_type"] == 0
                @test h["source_wavelength"] ≈ 0.97625 atol = 1e-9   # stored 97625 fm
                # The beam centre is in millimetres despite the C header calling it pixels:
                # dividing by the pixel size lands in the middle of a 3072-wide detector.
                @test 0.4 < (h["beam_x"] / h["pixelsize_x"]) / 3072 < 0.6
            end

            @testset "round-trips through writemarccd" begin
                orig = Fabio.readimage(ref)
                dst = joinpath(TMP, "marccd_roundtrip.mccd")
                Fabio.writemarccd(dst, collect(orig), header(orig))
                back = Fabio.readimage(dst)
                @test collect(back) == collect(orig)
                @test size(back) == size(orig)
                @test eltype(back) === eltype(orig)
                @test Fabio.openimage(f -> Fabio.imageformat(f), dst) isa Fabio.TIFFLike{:marccd}
                for (_, name, _) in Fabio.MARCCD_FIELDS
                    @test Float64(header(back)[name]) ≈ Float64(header(orig)[name]) atol = 1e-9
                end
                @test filesize(dst) == filesize(ref)
                # Writing back what we read is a fixed point.
                dst2 = joinpath(TMP, "marccd_roundtrip2.mccd")
                Fabio.writemarccd(dst2, collect(back), header(back))
                @test read(dst) == read(dst2)
            end

            @testset "the whole set reads consistently" begin
                for p in marccd_files
                    file = Fabio.openimage(p)
                    try
                        @test Fabio.imageformat(file) isa Fabio.TIFFLike{:marccd}
                        @test Fabio.pixeltype(file) === UInt16
                        @test length(file) == 1
                        frame = file[1]
                        h = header(frame)
                        @test size(frame) == (3072, 3072)
                        # The reader warns when these disagree; assert they never do.
                        @test (h["nfast"], h["nslow"]) == size(frame)
                        @test h["depth"] == sizeof(eltype(frame))
                    finally
                        close(file)
                    end
                end
            end
        end
    end
else
    @info "Skipping the real MarCCD tests; set FABIO_JL_MARCCD_TESTDATA to enable them"
end

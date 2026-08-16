# ---------------------------------------------------------------------------------------
# Real GE detector files, and one real plain TIFF, from the hexrd examples repository.
#
#   FABIO_JL_HEXRD_EXAMPLES=/path/to/hexrd/examples \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values come from the Python FabIO reading the same files.
# ---------------------------------------------------------------------------------------

const HEXRD_DATA = get(ENV, "FABIO_JL_HEXRD_EXAMPLES", "")

if !isempty(HEXRD_DATA) && isdir(HEXRD_DATA)
    gedir = joinpath(HEXRD_DATA, "NIST_ruby", "single_GE", "include")
    dcstiff = joinpath(HEXRD_DATA, "tests", "wppf", "texture", "DCS.tiff")

    @testset "GE and TIFF: real hexrd example files" begin
        if isdir(gedir)
            # (name, min, max, sum, position-sensitive checksum)
            refs = [
                ("RUBY_4553.ge", 1515, 16353, 9265684555),
                ("RUBY_4554.ge", 1515, 16353, 9263692388),
                ("RUBY_4555.ge", 1515, 16353, 8612565894),
            ]
            @testset "GE frames match FabIO" begin
                for (name, mn, mx, s) in refs
                    p = joinpath(gedir, name)
                    isfile(p) && filesize(p) > 0 || continue
                    file = Fabio.openimage(p)
                    try
                        @test Fabio.imageformat(file) isa GE
                        @test length(file) == 1
                        frame = file[1]
                        @test eltype(frame) === UInt16
                        @test size(frame) == (2048, 2048)
                        @test minimum(frame) == mn
                        @test maximum(frame) == mx
                        @test sum(Int64.(frame)) == s
                        @test !(Fabio.data(frame) isa Array)     # zero-copy mmap view
                    finally
                        close(file)
                    end
                end
            end

            @testset "the header is split across a standard and a user block" begin
                # Real GE files put 6144 bytes in the standard header and 2048 in the user
                # header, so the pixels begin at their sum rather than at either one. This
                # package's own writer emits 8192 + 0, so only a real file exercises it.
                p = joinpath(gedir, "RUBY_4553.ge")
                if isfile(p) && filesize(p) > 0
                    h = Fabio.readheader(p)
                    @test h["ImageFormat"] == "ADEPT"
                    @test h["StandardHeaderSizeInBytes"] == 6144
                    @test h["UserHeaderSizeInBytes"] == 2048
                    @test h["StandardHeaderSizeInBytes"] + h["UserHeaderSizeInBytes"] == 8192
                    @test h["NumberOfFrames"] == 1
                    @test h["NumberOfRowsInFrame"] == 2048
                    @test h["NumberOfColsInFrame"] == 2048
                    @test h["ImageDepthInBits"] == 16
                    @test h["HeaderBlanked"] === false
                    @test filesize(p) == 8192 + 2048 * 2048 * 2
                end
            end

            @testset "an empty placeholder is refused, not read as an image" begin
                p = joinpath(gedir, "RUBY_4537_background.ge")
                if isfile(p) && filesize(p) == 0
                    @test_throws Exception Fabio.openimage(p)
                end
            end
        else
            @info "hexrd NIST_ruby/single_GE not present; skipping the GE checks"
        end

        if isfile(dcstiff)
            @testset "a real Float32 TIFF" begin
                # Not a detector TIFF: 32-bit floats with SampleFormat 3, a combination that
                # otherwise only appears in fixtures written here.
                file = Fabio.openimage(dcstiff)
                try
                    @test Fabio.imageformat(file) isa Fabio.TIFFLike{:plain}
                    @test length(file) == 1
                    frame = file[1]
                    @test eltype(frame) === Float32
                    @test size(frame) == (2048, 2048)
                    h = header(frame)
                    @test h["BitsPerSample"] == 32
                    @test h["SampleFormat"] == 3
                    @test h["NumberOfStrips"] == 1
                    @test Float64(minimum(frame)) == 0.0
                    @test Float64(maximum(frame)) ≈ 223.61997985839844 rtol = 1e-12
                    @test sum(Float64.(collect(frame))) ≈ 9208202.64 rtol = 1e-9
                finally
                    close(file)
                end
            end
        else
            @info "hexrd DCS.tiff not present; skipping the Float32 TIFF check"
        end
    end
else
    @info "Skipping the hexrd example tests; set FABIO_JL_HEXRD_EXAMPLES to enable them"
end

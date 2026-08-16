# ---------------------------------------------------------------------------------------
# Real ADSC / d*TREK files. Opt-in, since they are large and not redistributable here.
#
#   FABIO_JL_ADSC_TESTDATA=/path/to/ADSC_data \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values come from the Python FabIO. The tree used to develop these tests holds two
# datasets that between them cover both byte orders and both of the detector sizes involved,
# and every file uses the older `TYPE=unsigned_short` convention rather than `Data_type`.
# ---------------------------------------------------------------------------------------

const ADSC_DATA = get(ENV, "FABIO_JL_ADSC_TESTDATA", "")

if !isempty(ADSC_DATA) && isdir(ADSC_DATA)
    adsc_files = String[]
    for (root, _, names) in walkdir(ADSC_DATA), n in names
        endswith(n, ".img") && push!(adsc_files, joinpath(root, n))
    end
    sort!(adsc_files)

    if isempty(adsc_files)
        @info "FABIO_JL_ADSC_TESTDATA has no .img files; skipping"
    else
        @testset "d*TREK / ADSC: real detector files" begin
            le = filter(p -> endswith(p, "tndpy1_tr_1_510.img"), adsc_files)
            be = filter(p -> endswith(p, "hralad1_1_270.img"), adsc_files)

            if !isempty(le)
                @testset "little-endian 3072² frame matches FabIO" begin
                    file = Fabio.openimage(first(le))
                    @test Fabio.imageformat(file) isa Fabio.Dtrek
                    @test length(file) == 1
                    frame = file[1]
                    @test eltype(frame) === UInt16
                    @test size(frame) == (3072, 3072)
                    @test minimum(frame) == 0
                    @test maximum(frame) == 7293
                    @test sum(Int64.(frame)) == 986066490
                    @test mean(frame) ≈ 104.4873650869 atol = 1e-8
                    # FabIO's d[0, :5] and d[1000, 1000:1005], in its (slow, fast) order.
                    @test collect(frame[1:5, 1]) == UInt16[0, 0, 0, 0, 0]
                    @test collect(frame[1001:1005, 1001]) == UInt16[156, 161, 157, 159, 157]
                    @test !(Fabio.data(frame) isa Array)      # native order, so a mmap view
                    h = header(frame)
                    @test h["BYTE_ORDER"] == "little_endian"
                    @test h["TYPE"] == "unsigned_short"
                    @test !haskey(h, "Data_type")             # the older convention
                    @test getheader(h, "HEADER_BYTES", Int) == 512
                    @test getheader(h, "SIZE1", Int) == 3072
                    @test getheader(h, "WAVELENGTH", Float64) ≈ 1.0736
                    @test getheader(h, "DISTANCE", Float64) ≈ 270.8
                    @test getheader(h, "BEAM_CENTER_X", Float64) ≈ 158.32
                    @test getheader(h, "PIXEL_SIZE", Float64) ≈ 0.102588
                    @test h["DETECTOR_SN"] == "918"
                    close(file)
                end
            else
                @info "tndpy1_tr_1_510.img not present; skipping the little-endian checks"
            end

            if !isempty(be)
                @testset "big-endian 2304² frame matches FabIO" begin
                    # A genuinely big-endian file: the reader has to byte-swap, which also
                    # means the frame cannot be handed back as a zero-copy mapping.
                    file = Fabio.openimage(first(be))
                    frame = file[1]
                    @test eltype(frame) === UInt16
                    @test size(frame) == (2304, 2304)
                    @test minimum(frame) == 0
                    @test maximum(frame) == 65535
                    @test sum(Int64.(frame)) == 2820486336
                    @test mean(frame) ≈ 531.3235315394 atol = 1e-8
                    @test collect(frame[1:5, 1]) == UInt16[20, 20, 20, 20, 20]
                    @test collect(frame[1001:1005, 1001]) == UInt16[350, 358, 355, 353, 357]
                    h = header(frame)
                    @test h["BYTE_ORDER"] == "big_endian"
                    @test getheader(h, "SIZE1", Int) == 2304
                    @test getheader(h, "WAVELENGTH", Float64) ≈ 0.933
                    @test h["DETECTOR_SN"] == "413"
                    close(file)
                end
            else
                @info "hralad1_1_270.img not present; skipping the big-endian checks"
            end

            @testset "a sample across the tree reads consistently" begin
                sample = adsc_files[1:max(1, length(adsc_files) ÷ 60):end]
                orders = Set{String}()
                sizes = Set{Tuple{Int,Int}}()
                for p in sample
                    file = Fabio.openimage(p)
                    try
                        @test Fabio.imageformat(file) isa Fabio.Dtrek
                        @test Fabio.pixeltype(file) === UInt16
                        @test length(file) == 1
                        frame = file[1]
                        h = header(frame)
                        @test size(frame) ==
                              (getheader(h, "SIZE1", Int), getheader(h, "SIZE2", Int))
                        @test getheader(h, "DIM", Int, 2) == 2
                        push!(orders, String(h["BYTE_ORDER"]))
                        push!(sizes, size(frame))
                    finally
                        close(file)
                    end
                end
                @test !isempty(orders)
                @info "sampled $(length(sample)) ADSC files: byte orders $(collect(orders)), sizes $(collect(sizes))"
            end
        end
    end
else
    @info "Skipping the real ADSC tests; set FABIO_JL_ADSC_TESTDATA to enable them"
end

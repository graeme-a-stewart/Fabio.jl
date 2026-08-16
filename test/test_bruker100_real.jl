# ---------------------------------------------------------------------------------------
# Real Bruker .sfrm files. Opt-in, since the sets are large and not redistributable here.
#
#   FABIO_JL_SFRM_TESTDATA=/path/to/sfrm_data \
#     julia --project -e 'using Pkg; Pkg.test()'
#
# Reference values come from the Python FabIO. The tree used to develop these tests holds
# 22637 files, of which 22616 are FORMAT:100 and 21 are FORMAT:86, so both readers get
# coverage from the same directory.
# ---------------------------------------------------------------------------------------

const SFRM_DATA = get(ENV, "FABIO_JL_SFRM_TESTDATA", "")

if !isempty(SFRM_DATA) && isdir(SFRM_DATA)
    sfrm_files = String[]
    for (root, _, names) in walkdir(SFRM_DATA), n in names
        endswith(n, ".sfrm") && push!(sfrm_files, joinpath(root, n))
    end
    sort!(sfrm_files)

    if isempty(sfrm_files)
        @info "FABIO_JL_SFRM_TESTDATA has no .sfrm files; skipping"
    else
        @testset "Bruker: real .sfrm files" begin
            ref = filter(p -> endswith(p, "cu_matrix_01_0001.sfrm"), sfrm_files)

            if !isempty(ref)
                @testset "FORMAT:100 frame matches FabIO" begin
                    file = Fabio.openimage(first(ref))
                    @test Fabio.imageformat(file) isa Fabio.Bruker{100}
                    frame = file[1]
                    @test eltype(frame) === Int32
                    @test size(frame) == (768, 1024)          # FabIO reports (1024, 768)
                    @test minimum(frame) == 0
                    @test maximum(frame) == 4339
                    @test sum(Int64.(frame)) == 50793759
                    @test mean(frame) ≈ 64.5876045227 atol = 1e-8
                    # FabIO's d[0, :6] and d[500, 300:306], in its (slow, fast) order.
                    @test collect(frame[1:6, 1]) == Int32[43, 67, 69, 53, 69, 48]
                    @test collect(frame[301:306, 501]) == Int32[69, 70, 72, 56, 68, 72]
                    h = header(frame)
                    @test getheader(h, "FORMAT", Int) == 100
                    @test getheader(h, "HDRBLKS", Int) == 15
                    @test strip(h["NOVERFL"]) == "-1                     77                     0"
                    close(file)
                end
            else
                @info "cu_matrix_01_0001.sfrm not present; skipping the FORMAT:100 reference checks"
            end

            @testset "both format versions are detected and read" begin
                # Walking every file is slow on a large tree, so sample across it while still
                # visiting enough files to hit each variant.
                sample = sfrm_files[1:max(1, length(sfrm_files) ÷ 200):end]
                seen100 = 0
                seen86 = 0
                for p in sample
                    file = Fabio.openimage(p)
                    try
                        fmt = Fabio.imageformat(file)
                        @test fmt isa Fabio.Bruker
                        frame = file[1]
                        h = header(frame)
                        if fmt isa Fabio.Bruker{100}
                            seen100 += 1
                            @test eltype(frame) === Int32
                        else
                            seen86 += 1
                            @test eltype(frame) <: Unsigned
                        end
                        # Bruker values carry several tokens ("512   2"), so take the first,
                        # exactly as the reader's own `_bruker_int` does.
                        firstint(k) = parse(Int, first(split(strip(h[k]))))
                        @test size(frame) == (firstint("NCOLS"), firstint("NROWS"))
                        @test minimum(frame) >= typemin(Int32)
                    finally
                        close(file)
                    end
                end
                @test seen100 > 0
                @info "sampled $(length(sample)) .sfrm files: $seen100 FORMAT:100, $seen86 FORMAT:86"
            end

            @testset "FORMAT:86 files in the same tree" begin
                # A handful of the files are the older format. Find them by reading headers
                # only, which is cheap, then check the FORMAT:86 reader on real data.
                v86 = String[]
                for p in sfrm_files
                    h = Fabio.readheader(p)
                    getheader(h, "FORMAT", Int, 86) == 86 && push!(v86, p)
                    length(v86) >= 6 && break
                end
                if isempty(v86)
                    @info "no FORMAT:86 files in this tree; skipping"
                else
                    for p in v86
                        file = Fabio.openimage(p)
                        try
                            @test Fabio.imageformat(file) isa Fabio.Bruker{86}
                            frame = file[1]
                            @test eltype(frame) <: Unsigned
                            @test minimum(frame) >= 0
                            h = header(frame)
                            firstint(k) = parse(Int, first(split(strip(h[k]))))
                            @test size(frame) == (firstint("NCOLS"), firstint("NROWS"))
                        finally
                            close(file)
                        end
                    end
                    @info "checked $(length(v86)) FORMAT:86 files"
                end
            end

            @testset "every correction path appears in the data" begin
                # These files are the reason the FORMAT:100 codec can be trusted: the tree
                # exercises 1- and 2-byte pixels, underflow tables and second-stage overflow.
                widths = Set{Int}()
                withunderflow = 0
                withoverflow2 = 0
                sample = sfrm_files[1:max(1, length(sfrm_files) ÷ 400):end]
                for p in sample
                    h = Fabio.readheader(p)
                    push!(widths, parse(Int, first(split(strip(h["NPIXELB"])))))
                    nov = split(strip(h["NOVERFL"]))
                    length(nov) >= 1 && parse(Int, nov[1]) > 0 && (withunderflow += 1)
                    length(nov) >= 3 && parse(Int, nov[3]) > 0 && (withoverflow2 += 1)
                end
                @test 1 in widths
                @test withunderflow > 0        # underflow substitution plus baseline
                @test withoverflow2 > 0        # two-stage escalation, 255 -> 65535 -> Int32
            end
        end
    end
else
    @info "Skipping the real Bruker .sfrm tests; set FABIO_JL_SFRM_TESTDATA to enable them"
end

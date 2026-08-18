# The HDF5 readers against real files, opt-in through FABIO_JL_HEXRD_EXAMPLES.
#
# Every expected value below was produced by the Python FabIO reading the same file, not
# written by hand. The Eiger frames are compared with an exact integer position-sensitive
# checksum, computed in `BigInt` on both sides, so there is no floating-point slack to hide a
# reordering.

const HEXRD_H5 = get(ENV, "FABIO_JL_HEXRD_EXAMPLES", "")

"""Exact position-sensitive checksum: the sum of each value times its 1-based flat index."""
function _h5bigchecksum(A)
    s = big(0)
    @inbounds for (i, v) in enumerate(vec(A))
        s += big(v) * i
    end
    return s
end

function _h5floatchecksum(A)
    s = 0.0
    @inbounds for (i, v) in enumerate(vec(A))
        s += Float64(v) * i
    end
    return s
end

"""
Whether the bitshuffle filter is available.

Real Eiger data is written with bitshuffle-LZ4, a plugin filter. It is not a dependency of
this package's test suite, so the pixel comparisons below run only when it happens to be
installed; the structural assertions need no filter and always run.
"""
function _h5_bitshuffle_available()
    try
        @eval import H5Zbitshuffle
        return true
    catch
        return false
    end
end

if isempty(HEXRD_H5) || !isdir(HEXRD_H5)
    @info "Skipping the real HDF5 tests; set FABIO_JL_HEXRD_EXAMPLES to enable them"
else
    @testset "real HDF5 files" begin
        @testset "flat container: ceria_ff1.h5" begin
            p = joinpath(HEXRD_H5, "dexelas", "ceria", "ceria_ff1.h5")
            if !isfile(p)
                @info "Skipping ceria_ff1.h5; not present under FABIO_JL_HEXRD_EXAMPLES"
            else
                # FabIO reads this as `Hdf5Image` via "ceria_ff1.h5::/data" and reports
                # shape (3888, 3072) float32 — the numpy transpose of the shape below.
                for spec in (p, p * "::/data")
                    Fabio.openimage(spec) do f
                        @test f.format == Fabio.NexusLike{:hdf5}()
                        @test length(f) == 1
                        @test pixeltype(f) == Float32
                        fr = f[1]
                        @test size(fr) == (3072, 3888)
                        @test minimum(fr) == 0.0f0
                        @test maximum(fr) == 16092.5f0
                        @test sum(Float64.(fr)) == 981504778.0
                        @test _h5floatchecksum(fr) == 5917050347040611.0
                    end
                end
            end
        end

        @testset "Eiger: ff_000_data_000001.h5" begin
            p = joinpath(HEXRD_H5, "eiger", "first_ceria", "ff_000_data_000001.h5")
            if !isfile(p)
                @info "Skipping ff_000_data_000001.h5; not present under FABIO_JL_HEXRD_EXAMPLES"
            else
                Fabio.openimage(p) do f
                    # Structure first: none of this needs the compression filter.
                    @test f.format == Fabio.NexusLike{:eiger}()
                    @test length(f) == 2
                    @test pixeltype(f) == UInt32
                    @test Fabio.framedims(f.frames[1]) == (4148, 4362)
                    # Through `readheader`, not `header(f[1])`: the latter would read the
                    # pixels, which is exactly what the filter is missing for.
                    @test Fabio.readheader(p)["HDF5Path"] == "/entry/data/data"

                    if _h5_bitshuffle_available()
                        # min, max, sum and checksum from FabIO reading this file.
                        refs = [
                            (0x00000000, 0xffffffff, 5519493027131822,
                             big"49934185196998070067691"),
                            (0x00000000, 0xffffffff, 5519493027017927,
                             big"49934185196075870941714"),
                        ]
                        for (i, (lo, hi, tot, chk)) in enumerate(refs)
                            fr = f[i]
                            @test size(fr) == (4148, 4362)
                            @test minimum(fr) == lo
                            @test maximum(fr) == hi
                            @test sum(UInt64.(fr)) == tot
                            @test _h5bigchecksum(fr) == chk
                        end
                    else
                        # Without the filter the read must fail in a way that says so, rather
                        # than returning wrong pixels.
                        err = try
                            f[1]
                            nothing
                        catch e
                            e
                        end
                        @test err isa Fabio.UnsupportedFormatError
                        @test occursin("bitshuffle", sprint(showerror, err))
                        @info "Real Eiger pixels not compared; `import H5Zbitshuffle` to enable"
                    end
                end
            end
        end
    end
end

using Fabio: TiffStrips

# Multi-strip TIFFs written by tifffile, an implementation independent of this package.
# See test/data/tiff/PROVENANCE.md for how they were made and why the scattered ones exist.
# The reference values below are the Python FabIO's, reading the same files.

const TIFFDIR = joinpath(@__DIR__, "data", "tiff")

"""Sum of value times flat index — catches a transposition or reordering that sums would not."""
function poschecksum(A)
    flat = vec(A)
    c = Int64(0)
    @inbounds for i in eachindex(flat)
        c += Int64(flat[i]) * Int64(i)
    end
    return c
end

# name => (fast, slow, eltype, min, max, sum, checksum, strips, contiguous)
const STRIP_CASES = (
    ("tf_u16_rps4.tif", 32, 40, UInt16, 7, 2999, 1927428, 1239625117, 10, true),
    ("tf_i32_rps3.tif", 18, 24, Int32, -773, 99904, 21659443, 4622752087, 8, true),
    ("tf_u16_be.tif", 32, 40, UInt16, 7, 2999, 1927428, 1239625117, 8, true),
    ("scatter_rev.tif", 32, 40, UInt16, 7, 2999, 1927428, 1239625117, 10, false),
    ("scatter_i32.tif", 18, 24, Int32, -773, 99904, 21659443, 4622752087, 8, false),
    ("scatter_be.tif", 32, 40, UInt16, 7, 2999, 1927428, 1239625117, 8, false),
)

@testset "TIFF strips (files written by tifffile)" begin
    @testset "$name" for (name, fast, slow, T, mn, mx, s, chk, nstrips, contiguous) in STRIP_CASES
        p = joinpath(TIFFDIR, name)
        @test isfile(p)
        file = Fabio.openimage(p)
        try
            frame = file[1]
            @test eltype(frame) === T
            @test size(frame) == (fast, slow)
            @test minimum(frame) == mn
            @test maximum(frame) == mx
            @test sum(Int64.(frame)) == s
            @test poschecksum(collect(frame)) == chk
            @test header(frame)["NumberOfStrips"] == nstrips

            layout = file.frames[1].layout
            if contiguous
                # Consecutive strips are still one run of bytes, so they stay tier 1 and keep
                # the memory-mapped fast path.
                @test layout isa Fabio.BinaryLayout
            else
                # Disjoint strips cannot be described by a single BinaryLayout.
                @test layout isa TiffStrips
                @test length(layout.offsets) == nstrips
                @test Fabio.data(frame) isa Array      # gathered, so owned
            end
        finally
            close(file)
        end
    end

    @testset "every layout of the same image gives the same pixels" begin
        # tf_u16_rps4, tf_u16_be and scatter_* all encode one array, at different strip
        # counts, byte orders and placements. Disagreement between them would mean a
        # strip-handling bug rather than a bad reference value.
        variants = ["tf_u16_rps4.tif", "tf_u16_be.tif", "scatter_rev.tif", "scatter_be.tif"]
        arrays = [collect(Fabio.readimage(joinpath(TIFFDIR, v))) for v in variants]
        for a in arrays[2:end]
            @test a == arrays[1]
        end
    end

    @testset "strips are followed by offset, not by file order" begin
        # scatter_rev.tif stores its strips in reverse: the last rows of the image sit
        # earliest in the file. A reader that walked the file instead of the offsets table
        # would return a vertically scrambled image with an identical sum.
        p = joinpath(TIFFDIR, "scatter_rev.tif")
        file = Fabio.openimage(p)
        try
            layout = file.frames[1].layout
            @test layout isa TiffStrips
            @test !issorted(layout.offsets)          # genuinely out of order in the file
            frame = file[1]
            @test poschecksum(collect(frame)) == 1239625117
        finally
            close(file)
        end
    end
end

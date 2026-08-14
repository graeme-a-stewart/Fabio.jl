using Fabio: PCK, PCK_BIT_COUNT, pck_unpack, pck_postdecode!

"""
A minimal PCK bit-writer, enough to build fixtures by hand.

Blocks are `(nbits, values)`; `nbits` of 0 emits a zero-run of `length(values)`. The block
header is six bits — `log2(count)` in the low three, the index into `PCK_BIT_COUNT` in the
next three — followed by the values at `nbits` each, everything LSB-first.
"""
mutable struct PckWriter
    buf::Vector{UInt8}
    nbits::Int
end
PckWriter() = PckWriter(UInt8[], 0)

function pushbits!(w::PckWriter, value::Integer, n::Integer)
    # `%` reinterprets, so negative values pack as their two's-complement bit pattern.
    v = (value % UInt64) & ((UInt64(1) << n) - UInt64(1))
    for i = 0:(n-1)
        byte, bit = divrem(w.nbits, 8)
        bit == 0 && push!(w.buf, 0x00)
        if (v >> i) & 1 == 1
            w.buf[byte+1] |= UInt8(1) << bit
        end
        w.nbits += 1
    end
    return w
end

function pushblock!(w::PckWriter, nbits::Int, values::AbstractVector{<:Integer})
    n = length(values)
    ispow2(n) || error("a PCK block holds a power-of-two number of values, got $n")
    sizeidx = findfirst(==(nbits), PCK_BIT_COUNT)
    sizeidx === nothing && error("$nbits is not a PCK value width")
    pushbits!(w, trailing_zeros(n) | ((sizeidx - 1) << 3), 6)
    nbits == 0 && return w
    for v in values
        pushbits!(w, v, nbits)
    end
    return w
end

@testset "PCK codec" begin
    @testset "bit unpacking round-trips through the hand writer" begin
        w = PckWriter()
        pushblock!(w, 4, Int[1, -2, 3, -4])
        pushblock!(w, 8, Int[100, -100, 0, 27, 5, -5, 1, -1])
        out = pck_unpack(w.buf, 12)
        @test out == Int32[1, -2, 3, -4, 100, -100, 0, 27, 5, -5, 1, -1]
    end

    @testset "sign extension at every supported width" begin
        for nbits in (4, 5, 6, 7, 8, 16, 32)
            lo = -(1 << (nbits - 1))
            hi = (1 << (nbits - 1)) - 1
            vals = Int[lo, hi, -1, 0]
            w = PckWriter()
            pushblock!(w, nbits, vals)
            @test pck_unpack(w.buf, 4) == Int32.(vals)
        end
    end

    @testset "zero runs" begin
        w = PckWriter()
        pushblock!(w, 0, zeros(Int, 16))
        pushblock!(w, 4, Int[7, 7, 7, 7])
        out = pck_unpack(w.buf, 20)
        @test out[1:16] == zeros(Int32, 16)
        @test out[17:20] == Int32[7, 7, 7, 7]
    end

    @testset "blocks that straddle byte boundaries" begin
        # 5-bit values never align with bytes, so every block header lands mid-byte.
        vals = Int[3, -3, 7, -7, 15, -15, 1, -1]
        w = PckWriter()
        for _ = 1:5
            pushblock!(w, 5, vals)
        end
        @test pck_unpack(w.buf, 40) == repeat(Int32.(vals), 5)
    end

    @testset "post-decoding: constant and ramp images" begin
        # All-zero differences reconstruct to zero.
        @test pck_postdecode!(zeros(Int32, 32), 8) == zeros(UInt32, 32)

        # A single leading value with zero differences gives a constant image: the
        # neighbour mean of four equal values reproduces the same value.
        comp = zeros(Int32, 32)
        comp[1] = 5
        @test pck_postdecode!(comp, 8) == fill(UInt32(5), 32)

        # The first row accumulates from the previous value only.
        comp = zeros(Int32, 24)
        comp[1:9] .= Int32(1)
        img = pck_postdecode!(comp, 8)
        @test img[1:9] == UInt32.(1:9)
    end

    @testset "overflow values are patched in" begin
        # Counts above 65535 cannot survive the 16-bit reconstruction, so mar345 carries
        # them in a separate table. Indices are 1-based flat positions in raster order.
        w = PckWriter()
        pushblock!(w, 0, zeros(Int, 32))
        idx = Int32[3, 17, 32]
        val = Int32[70000, 123456, 65536]
        out = decode(PCK(idx, val), w.buf, UInt32, (8, 4))
        @test out[3] == 70000
        @test out[17] == 123456
        @test out[32] == 65536
        @test sum(out) == UInt32(70000) + UInt32(123456) + UInt32(65536)
    end

    @testset "out-of-range overflow indices are ignored, not fatal" begin
        w = PckWriter()
        pushblock!(w, 0, zeros(Int, 16))
        out = decode(PCK(Int32[0, -5, 99, 4], Int32[1, 2, 3, 42]), w.buf, UInt32, (4, 4))
        @test out[4] == 42
        @test sum(out) == 42          # the three bogus indices were skipped
    end

    @testset "only UInt32 is meaningful" begin
        w = PckWriter()
        pushblock!(w, 0, zeros(Int, 4))
        @test_throws Fabio.UnsupportedFormatError decode(PCK(), w.buf, Int32, (2, 2))
    end
end

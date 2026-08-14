using Fabio: _agi_decode_sequential!, _agi_decode_indexed!

"""Assemble an AGI bitfield blob from per-row byte strings, appending the row-offset table."""
function agi_blob(rows::Vector{Vector{UInt8}})
    stream = UInt8[]
    starts = UInt32[]
    for r in rows
        push!(starts, UInt32(length(stream)))
        append!(stream, r)
    end
    blob = UInt8[]
    append!(blob, reinterpret(UInt8, [htol(UInt32(length(stream)))]))
    append!(blob, stream)
    append!(blob, reinterpret(UInt8, htol.(starts)))
    return blob
end

esc(v::Integer) = UInt8[UInt8(v + 127)]
esc16(v::Integer) = vcat(UInt8[0xFE], reinterpret(UInt8, [htol(Int16(v))]))
esc32(v::Integer) = vcat(UInt8[0xFF], reinterpret(UInt8, [htol(Int32(v))]))

@testset "AGI bitfield codec" begin
    @testset "short rows use only escaped bytes" begin
        # A 4-pixel row: first pixel 5, then differences +2, -1, +3.
        row = vcat(esc(5), esc(2), esc(-1), esc(3))
        blob = agi_blob([row, row])
        out = decode(AGIBitfield(), blob, Int32, (4, 2))
        @test out[:, 1] == Int32[5, 7, 6, 9]      # cumulative sum along the detector row
        @test out[:, 2] == Int32[5, 7, 6, 9]
    end

    @testset "16-bit and 32-bit escapes" begin
        row = vcat(esc(0), esc16(1000), esc32(-100000), esc(1))
        out = decode(AGIBitfield(), agi_blob([row]), Int32, (4, 1))
        @test out[:, 1] == cumsum(Int32[0, 1000, -100000, 1])
    end

    @testset "packed fields: two nibbles, two widths" begin
        # 17 pixels = 1 field group of 16 + 0 remainder.
        # field a: 2-bit values, bias 1, encoding differences [1,0,-1,2,1,0,-1,2]
        # field b: 1-bit values, bias 0, all zero
        lb = UInt8(0x12)                      # high nibble = len_b = 1, low = len_a = 2
        row = vcat(esc(100), [lb], UInt8[0xC6, 0xC6], UInt8[0x00])
        out = decode(AGIBitfield(), agi_blob([row]), Int32, (17, 1))
        expected = cumsum(Int32[100, 1, 0, -1, 2, 1, 0, -1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        @test out[:, 1] == expected
    end

    @testset "escapes inside an 8-bit field are read after both fields" begin
        # The ordering matters: FabIO reads field a's bytes, then field b's bytes, and only
        # then the escape values for a followed by those for b.
        lb = UInt8(0x18)                      # len_b = 1, len_a = 8
        fielda = UInt8[0x7F, 0x7F, 0xFE, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F]
        fieldb = UInt8[0x00]
        escapes = reinterpret(UInt8, [htol(Int16(1000))])
        row = vcat(esc(0), [lb], fielda, fieldb, escapes)
        out = decode(AGIBitfield(), agi_blob([row]), Int32, (17, 1))
        expected = cumsum(Int32[0, 0, 0, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        @test out[:, 1] == expected
    end

    @testset "indexed decode agrees with sequential decode" begin
        rows = [vcat(esc(i), esc(1), esc(-1), esc(i)) for i = 1:8]
        blob = agi_blob(rows)
        datasize = Int(Fabio._load_u32(blob, 1))
        starts = UInt32[]
        acc = 0
        for r in rows
            push!(starts, UInt32(acc))
            acc += length(r)
        end

        seq = Matrix{Int32}(undef, 4, 8)
        _agi_decode_sequential!(seq, blob)
        idx = Matrix{Int32}(undef, 4, 8)
        _agi_decode_indexed!(idx, blob, starts, datasize)
        @test seq == idx
    end

    @testset "corrupt input is rejected, not silently mis-decoded" begin
        # A zero-length field cannot occur in valid data; FabIO would apply a nonsense bias.
        row = vcat(esc(0), UInt8[0x10], UInt8[0x00])
        @test_throws Fabio.CorruptFileError decode(
            AGIBitfield(),
            agi_blob([row]),
            Int32,
            (17, 1),
        )

        @test_throws Fabio.TruncatedFileError decode(AGIBitfield(), UInt8[0x01, 0x02], Int32, (4, 1))

        # A declared block larger than the bytes present.
        bad = vcat(reinterpret(UInt8, [htol(UInt32(9999))]), UInt8[0x00, 0x00])
        @test_throws Fabio.TruncatedFileError decode(AGIBitfield(), bad, Int32, (4, 1))

        # Row offsets pointing past the data block.
        rows = [vcat(esc(0), esc(0), esc(0), esc(0))]
        blob = agi_blob(rows)
        @test_throws Fabio.CorruptFileError _agi_decode_indexed!(
            Matrix{Int32}(undef, 4, 1),
            blob,
            UInt32[9999],
            Int(Fabio._load_u32(blob, 1)),
        )
    end

    @testset "only Int32 is meaningful" begin
        row = vcat(esc(0), esc(0), esc(0), esc(0))
        @test_throws Fabio.UnsupportedFormatError decode(
            AGIBitfield(),
            agi_blob([row]),
            Float32,
            (4, 1),
        )
    end
end

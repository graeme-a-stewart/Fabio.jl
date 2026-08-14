@testset "NPY" begin
    @testset "round-trip" begin
        for T in (UInt8, Int16, UInt16, Int32, Float32, Float64)
            A = rand(T, 6, 4)
            p = joinpath(TMP, "rt_$T.npy")
            writenpy(p, A)
            frame = Fabio.readimage(p)
            @test eltype(frame) === T
            @test size(frame) == (6, 4)
            @test collect(frame) == A
        end
    end

    @testset "C-ordered files map in without permutation" begin
        # A numpy C-ordered array of shape (rows, cols) is byte-for-byte a Julia
        # (cols, rows) array — the identity behind this package's axis convention.
        rows, cols = 3, 5
        payload = reinterpret(UInt8, UInt16[10i + j for i = 1:rows for j = 1:cols])
        dict = "{'descr': '<u2', 'fortran_order': False, 'shape': ($rows, $cols), }"
        dict = dict * " "^mod(-(10 + length(dict) + 1), 64) * "\n"
        p = joinpath(TMP, "corder.npy")
        Base.open(p, "w") do io
            write(io, Fabio.NPY_MAGIC)
            write(io, UInt8(1), UInt8(0))
            write(io, htol(UInt16(length(dict))))
            write(io, codeunits(dict))
            write(io, payload)
        end
        frame = Fabio.readimage(p)
        @test size(frame) == (cols, rows)          # (fast, slow)
        @test size(Fabio.rowmajor(frame)) == (rows, cols)
        @test Fabio.rowmajor(frame)[2, 4] == UInt16(24)
    end

    @testset "big-endian dtype" begin
        A = UInt16[1 2; 3 4]
        dict = "{'descr': '>u2', 'fortran_order': True, 'shape': (2, 2), }"
        dict = dict * " "^mod(-(10 + length(dict) + 1), 64) * "\n"
        p = joinpath(TMP, "bigend.npy")
        Base.open(p, "w") do io
            write(io, Fabio.NPY_MAGIC)
            write(io, UInt8(1), UInt8(0))
            write(io, htol(UInt16(length(dict))))
            write(io, codeunits(dict))
            write(io, reinterpret(UInt8, vec(bswap.(A))))
        end
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "header metadata is exposed" begin
        writenpy(joinpath(TMP, "meta.npy"), Int32[1 2; 3 4])
        h = Fabio.readheader(joinpath(TMP, "meta.npy"))
        @test h["descr"] == "<i4"
        @test h["fortran_order"] === true
        @test h["shape"] == (2, 2)
    end
end

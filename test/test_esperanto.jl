"""
Build a synthetic Esperanto file with the given pixel data, using the uncompressed
`4BYTE_LONG` encoding. Exercises the header parser without needing an encoder.
"""
function write_esperanto_4byte(path, A::Matrix{Int32}; nlines = 25)
    W = 256
    lines = String[]
    push!(
        lines,
        "ESPERANTO FORMAT   1 CONSISTING OF   $nlines LINES OF   $W BYTES EACH",
    )
    push!(lines, "IMAGE $(size(A,1)) $(size(A,2)) 1 1 \"4BYTE_LONG\"")
    push!(lines, "SPECIAL_CCD_1 0 0 0 0 0 0")
    push!(lines, "TIME 1.5 0 0")
    push!(lines, "PIXELSIZE 0.2 0.2 0.2")
    push!(lines, "WAVELENGTH 0.29 0.29 0.29 0.29")
    push!(lines, "GONIOMODEL_1 0 0 0 0 0 1024 0 0 0 400.0")
    push!(lines, "STARTANGLESINDEG 0 0 0 -35.0")
    push!(lines, "MONOCHROMATOR 0.98 \"SYNCHROTRON\"")
    while length(lines) < nlines
        push!(lines, "")
    end
    Base.open(path, "w") do io
        for (i, l) in enumerate(lines)
            body = rpad(l, W - 2)
            write(io, codeunits(body))
            write(io, i == nlines ? UInt8[0x0D, 0x1A] : UInt8[0x0D, 0x0A])
        end
        write(io, encode(RawBlob(), A))
    end
    return path
end

@testset "Esperanto" begin
    @testset "header parsing and 4BYTE_LONG data" begin
        A = Int32[1 2 3 4; 5 6 7 8; 9 10 11 12; 13 14 15 16]
        p = write_esperanto_4byte(joinpath(TMP, "synthetic.esperanto"), A)

        frame = Fabio.readimage(p)
        @test eltype(frame) === Int32
        @test size(frame) == (4, 4)
        @test collect(frame) == A

        h = header(frame)
        @test h["lnx"] === 4                      # decoded by the `l` prefix convention
        @test h["lny"] === 4
        @test h["spixelformat"] == "4BYTE_LONG"
        @test h["dexposuretimeinsec"] === 1.5     # `d` prefix -> Float64
        @test h["drealpixelsizex"] === 0.2
        @test h["ddistanceinmm"] === 400.0
        @test h["dalpha1"] === 0.29
        @test h["dph_s"] === -35.0
        @test h["orientation-type"] == "SYNCHROTRON"
        @test h["IMAGE"] == "4 4 1 1 \"4BYTE_LONG\""   # the raw line is kept too
    end

    @testset "detection by magic, not extension" begin
        A = Int32[1 2; 3 4]
        p = write_esperanto_4byte(joinpath(TMP, "nameless.dat"), A)
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), p) === :Esperanto
    end

    @testset "unknown pixel formats are refused" begin
        A = Int32[1 2; 3 4]
        p = write_esperanto_4byte(joinpath(TMP, "weird.esperanto"), A)
        raw = read(p)
        p2 = joinpath(TMP, "weird2.esperanto")
        write(p2, Vector{UInt8}(codeunits(replace(String(copy(raw)), "4BYTE_LONG" => "8BYTE_LONG"))))
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(p2)
    end

    @testset "coerce enforces the format's shape constraints" begin
        # Esperanto demands a square image whose side is a multiple of 4 in [256, 4096].
        out = coerce(Esperanto(), zeros(Int32, 100, 60))
        @test size(out) == (256, 256)
        @test eltype(out) === Int32

        out = coerce(Esperanto(), ones(Int32, 300, 300))
        @test size(out) == (300, 300)

        out = coerce(Esperanto(), ones(Int32, 301, 301))
        @test size(out) == (304, 304)

        # Floats are rounded to integers, as FabIO's documentation describes for conversion.
        out = @test_logs (:info,) (:info,) coerce(Esperanto(), fill(2.7, 10, 10))
        @test eltype(out) === Int32
        @test out[129, 1] == 3
    end
end

# ---------------------------------------------------------------------------------------
# Real detector data. Opt-in, because these files are not redistributable.
#   FABIO_JL_LOCAL_TESTDATA=/path/to/01_enstatite_data julia --project -e 'using Pkg; Pkg.test()'
# ---------------------------------------------------------------------------------------

const LOCAL_DATA = get(ENV, "FABIO_JL_LOCAL_TESTDATA", "")

if !isempty(LOCAL_DATA) && isdir(LOCAL_DATA)
    @testset "Esperanto: real AGI_BITFIELD files" begin
        files = sort(filter(f -> endswith(f, ".esperanto"), readdir(LOCAL_DATA; join = true)))
        @test !isempty(files)

        ref = first(filter(f -> endswith(f, "enst_s1_1_1.esperanto"), files))

        @testset "reference frame matches FabIO" begin
            frame = Fabio.readimage(ref)
            @test eltype(frame) === Int32
            @test size(frame) == (2048, 2048)
            @test minimum(frame) == -4957
            @test maximum(frame) == 58167
            @test sum(Int64.(frame)) == 306910208
            @test mean(frame) ≈ 73.173096 atol = 1e-5
            @test std(frame; corrected = false) ≈ 147.530006 atol = 1e-4
            # FabIO reports d[0, :5] in numpy (slow, fast) order; ours is the fast axis.
            @test collect(frame[1:5, 1]) == Int32[0, 6, -1, 6, 3]
        end

        @testset "indexed and sequential decoding agree" begin
            Fabio.openimage(ref) do file
                layout = file.frames[1].layout
                @test layout.codec isa AGIBitfield
                @test length(layout.codec.rowstart) == 2048   # the table FabIO discards
                raw = bytes(file.source, layout.offset, layout.nbytes)
                seq = Matrix{Int32}(undef, 2048, 2048)
                _agi_decode_sequential!(seq, raw)
                idx = Matrix{Int32}(undef, 2048, 2048)
                _agi_decode_indexed!(
                    idx,
                    raw,
                    layout.codec.rowstart,
                    Int(Fabio._load_u32(raw, 1)),
                )
                @test seq == idx
            end
        end

        @testset "a sweep over the series" begin
            for f in files[1:min(5, end)]
                frame = Fabio.readimage(f)
                @test size(frame) == (2048, 2048)
                @test eltype(frame) === Int32
            end
        end
    end
else
    @info "Skipping the real-data Esperanto tests; set FABIO_JL_LOCAL_TESTDATA to enable them"
end

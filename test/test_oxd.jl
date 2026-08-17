using Fabio: OxdTY1, OxdTY5, OXD_GENERAL_FIELDS, OXD_KM4_FIELDS

# --------------------------------------------------------------------------------------
# A small Oxford Diffraction writer. The ASCII header is fixed-column, so the field
# positions here are the ones the reader looks at.
# --------------------------------------------------------------------------------------

"""Encode a frame with TY1: a byte plane plus separate Int16 and Int32 escape tables."""
function ty1_encode(A::Matrix{<:Integer})
    plane = UInt8[]
    esc16 = Int16[]
    esc32 = Int32[]
    acc = 0
    for v in vec(A)
        d = Int(v) - acc
        acc = Int(v)
        if -127 <= d <= 126
            push!(plane, UInt8(d + 127))
        elseif -32768 <= d <= 32767
            push!(plane, 0xFE)
            push!(esc16, Int16(d))
        else
            push!(plane, 0xFF)
            push!(esc32, Int32(d))
        end
    end
    payload = copy(plane)
    for v in esc16
        append!(payload, reinterpret(UInt8, [htol(v)]))
    end
    for v in esc32
        append!(payload, reinterpret(UInt8, [htol(v)]))
    end
    return payload, length(esc16), length(esc32)
end

"""Encode a frame with TY5: one interleaved stream, differences restarting each row."""
function ty5_encode(A::Matrix{<:Integer})
    out = UInt8[]
    nfast = size(A, 1)
    flat = vec(A)
    acc = 0
    for (i, v) in pairs(flat)
        (i - 1) % nfast == 0 && (acc = 0)
        d = Int(v) - acc
        acc = Int(v)
        if -127 <= d <= 126
            push!(out, UInt8(d + 127))
        elseif -32768 <= d <= 32767
            push!(out, 0xFE)
            append!(out, reinterpret(UInt8, [htol(Int16(d))]))
        else
            push!(out, 0xFF)
            append!(out, reinterpret(UInt8, [htol(Int32(d))]))
        end
    end
    return out
end

function write_oxd(path, A::Matrix{<:Integer}; compression = "TY1", km4 = Dict{String,Any}())
    d1, d2 = size(A)
    payload, oi, ol = if compression == "TY1"
        ty1_encode(A)
    elseif compression == "TY5"
        (ty5_encode(A), 0, 0)
    else
        (reduce(vcat, (collect(reinterpret(UInt8, [htol(Int32(v))])) for v in vec(A));
                init = UInt8[]), 0, 0)
    end

    gensize, specsize, km4size, statsize, histsize = 512, 768, 1024, 512, 0
    asciisize = 256
    headersize = asciisize + gensize + specsize + km4size + statsize + histsize

    # The whole ASCII section is 256 bytes holding six short CRLF-terminated lines, and every
    # field is read by fixed column, so the spacing below is load-bearing.
    lines = String[
        "OD SAPPHIRE  3.0",
        "COMPRESSION=$compression (bytes)",
        "NX=$(lpad(d1,4)) NY=$(lpad(d2,4)) OI=$(lpad(oi,7)) OL=$(lpad(ol,7))",
        "NHEADER=$(lpad(headersize,7)) NG=$(lpad(gensize,7)) NS=$(lpad(specsize,7)) " *
        "NK=$(lpad(km4size,7)) NS=$(lpad(statsize,7)) NH=$(lpad(histsize,7))",
        "NSUPPLEMENT=$(lpad(0,7))",
        "TIME=Mon Jan 01 00:00:00 2020",
    ]
    ascii = Vector{UInt8}()
    for l in lines
        append!(ascii, Vector{UInt8}(codeunits(l)))
        append!(ascii, UInt8[0x0d, 0x0a])
    end
    length(ascii) <= asciisize || error("OXD ASCII header overflows its $asciisize bytes")
    append!(ascii, fill(UInt8(' '), asciisize - length(ascii)))

    general = zeros(UInt8, gensize)
    put16(buf, off, v) = (buf[(off+1):(off+2)] = reinterpret(UInt8, [htol(UInt16(v))]))
    put32(buf, off, v) = (buf[(off+1):(off+4)] = reinterpret(UInt8, [htol(UInt32(v))]))
    putf64(buf, off, v) = (buf[(off+1):(off+8)] = reinterpret(UInt8, [htol(Float64(v))]))
    put16(general, 0, 1)
    put16(general, 2, 1)
    put16(general, 26, d1)
    put16(general, 28, d2)
    put32(general, 36, d1 * d2)

    special = zeros(UInt8, specsize)
    putf64(special, 56, 1.25)                    # Gain
    putf64(special, 480, 2.5)                    # Exposure time in sec

    km4block = zeros(UInt8, km4size)
    for (off, name, kind) in OXD_KM4_FIELDS
        haskey(km4, name) || continue
        putf64(km4block, off, km4[name])
    end

    stat = zeros(UInt8, statsize)
    put32(stat, 0, minimum(A) % UInt32)
    put32(stat, 4, maximum(A) % UInt32)

    Base.open(path, "w") do f
        Base.write(f, ascii)
        Base.write(f, general)
        Base.write(f, special)
        Base.write(f, km4block)
        Base.write(f, stat)
        Base.write(f, payload)
    end
    return path
end

@testset "OXD" begin
    @testset "TY1 round-trip, including both escape levels" begin
        # Values chosen so successive differences land in the byte, Int16 and Int32 classes.
        A = Int32[1 2 3; 100 20000 5; 200000 7 8]
        p = joinpath(TMP, "ty1.img")
        write_oxd(p, A; compression = "TY1")
        frame = Fabio.readimage(p)
        @test Fabio.openimage(f -> Fabio.imageformat(f), p) isa OXD
        @test eltype(frame) === Int32
        @test size(frame) == (3, 3)
        @test collect(frame) == A
        @test header(frame)["Compression"] == "TY1"
    end

    @testset "TY5 round-trip" begin
        A = Int32[1 2 3; 100 20000 5; 200000 7 8]
        p = joinpath(TMP, "ty5.img")
        write_oxd(p, A; compression = "TY5")
        frame = Fabio.readimage(p)
        @test eltype(frame) === Int32
        @test collect(frame) == A
        @test header(frame)["Compression"] == "TY5"
    end

    @testset "TY5 differences restart on each row, not each column" begin
        # A non-square frame is what separates the two readings: FabIO restarts every NY
        # pixels, using the slow dimension where the row length is the fast one, which on a
        # square detector is invisible and here is not.
        A = Int32[10i + j for i = 1:7, j = 1:3]      # 7 fast, 3 slow
        p = joinpath(TMP, "ty5_nonsquare.img")
        write_oxd(p, A; compression = "TY5")
        frame = Fabio.readimage(p)
        @test size(frame) == (7, 3)
        @test collect(frame) == A
        # Each row starts from zero, so the first pixel of each row is its own value.
        @test frame[1, 1] == A[1, 1]
        @test frame[1, 2] == A[1, 2]
        @test frame[1, 3] == A[1, 3]
    end

    @testset "TY1 accumulates across rows, TY5 does not" begin
        # The same frame encoded both ways gives different streams, since TY1 carries its
        # running total over row boundaries and TY5 restarts.
        A = Int32[10i + j for i = 1:5, j = 1:4]
        p1 = joinpath(TMP, "cmp_ty1.img")
        p5 = joinpath(TMP, "cmp_ty5.img")
        write_oxd(p1, A; compression = "TY1")
        write_oxd(p5, A; compression = "TY5")
        @test collect(Fabio.readimage(p1)) == A
        @test collect(Fabio.readimage(p5)) == A
        @test read(p1) != read(p5)
    end

    @testset "uncompressed frames" begin
        A = Int32[1 2; 3 4]
        p = joinpath(TMP, "raw.img")
        write_oxd(p, A; compression = "NO")
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "the binary sections are read" begin
        A = Int32[1 2; 3 4]
        p = joinpath(TMP, "hdr.img")
        write_oxd(p, A; km4 = Dict{String,Any}(
            "Wavelength alpha1" => 0.7107, "Distance in mm" => 45.0,
            "Beam center x" => 512.5, "Beam center y" => 513.25))
        h = Fabio.readheader(p)
        @test h["NX"] == 2 && h["NY"] == 2
        @test h["Pixels in x"] == 2
        @test h["Binning in x"] == 1
        @test h["No of pixels"] == 4
        @test h["Gain"] ≈ 1.25
        @test h["Exposure time in sec"] ≈ 2.5
        @test h["Wavelength alpha1"] ≈ 0.7107
        @test h["Distance in mm"] ≈ 45.0
        @test h["Beam center x"] ≈ 512.5
        @test h["Stat: Min"] == 1
        @test h["Stat: Max"] == 4
        # FabIO spells these keys with a trailing space; stripped here.
        @test !haskey(h, "Stat: Min ")
    end

    @testset "an unknown compression is refused" begin
        A = Int32[1 2; 3 4]
        p = joinpath(TMP, "unknown.img")
        write_oxd(p, A; compression = "TY9")
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(p)
    end

    @testset "a stream that outruns its escape tables is caught" begin
        A = Int32[1 20000 3; 4 5 6; 7 8 9]
        p = joinpath(TMP, "shortesc.img")
        write_oxd(p, A; compression = "TY1")
        raw = read(p)
        # Claim no 16-bit escapes while the byte plane still contains one.
        txt = String(raw[1:768])
        i = findfirst("OI=", txt)
        raw[(first(i)+3):(first(i)+9)] = Vector{UInt8}(codeunits(lpad(0, 7)))
        q = joinpath(TMP, "shortesc2.img")
        write(q, raw)
        @test_throws Fabio.FabioError Fabio.readimage(q)
    end

    @testset "a truncated TY5 stream is caught" begin
        A = Int32[10i + j for i = 1:6, j = 1:4]
        p = joinpath(TMP, "shortty5.img")
        write_oxd(p, A; compression = "TY5")
        raw = read(p)
        q = joinpath(TMP, "shortty5b.img")
        write(q, raw[1:end-10])
        @test_throws Fabio.TruncatedFileError Fabio.readimage(q)
    end
end

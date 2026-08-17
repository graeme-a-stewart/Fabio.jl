using Fabio: writekcd, writempa, KcdReadouts, MpaASCII

@testset "KCD" begin
    @testset "round-trip at one and several readouts" begin
        for readouts in (1, 2, 5)
            A = Int32[10i + j for i = 1:7, j = 1:5]
            p = joinpath(TMP, "rt_$readouts.kcd")
            writekcd(p, A; readouts = readouts)
            frame = Fabio.readimage(p)
            # The readouts are summed, so the element type is Int32 whatever the count.
            @test eltype(frame) === Int32
            @test size(frame) == (7, 5)
            @test collect(frame) == A
            @test header(frame)["Number of readouts"] == string(readouts)
        end
    end

    @testset "readouts really are summed, not treated as frames" begin
        A = Int32[100 200; 300 400]
        p = joinpath(TMP, "sum.kcd")
        writekcd(p, A; readouts = 4)
        file = Fabio.openimage(p)
        try
            @test length(file) == 1              # one image, not four
            @test collect(file[1]) == A
            # The stored values are each about a quarter of the total.
            @test filesize(p) > 4 * 2 * length(A)
        finally
            close(file)
        end
    end

    @testset "the ASCII header" begin
        p = joinpath(TMP, "hdr.kcd")
        writekcd(p, Int32[1 2; 3 4];
                 extra = Dict("Wavelength" => 0.7107, "Detector distance" => 40.0))
        h = Fabio.readheader(p)
        @test getheader(h, "X dimension", Int) == 2
        @test getheader(h, "Y dimension", Int) == 2
        @test h["Data type"] == "u16"
        @test getheader(h, "Wavelength", Float64) ≈ 0.7107
        @test getheader(h, "Detector distance", Float64) ≈ 40.0
    end

    @testset "pixels are located from the end of the file" begin
        A = Int32[7 8; 9 10]
        p = joinpath(TMP, "tail.kcd")
        writekcd(p, A)
        raw = read(p)
        # Padding inserted into the header region must not shift the data, since the pixel
        # block is anchored to the end of the file.
        cut = findfirst(==(UInt8('\n')), raw)
        padded = joinpath(TMP, "tail_padded.kcd")
        write(padded, vcat(raw[1:cut], Vector{UInt8}(codeunits("Comment = x\n")), raw[(cut+1):end]))
        @test collect(Fabio.readimage(padded)) == A
    end

    @testset "a missing shape is refused" begin
        p = joinpath(TMP, "noshape.kcd")
        write(p, Vector{UInt8}(codeunits("Nonius\nData type = u16\nEnd\n" * "\0"^64)))
        @test_throws Fabio.CorruptFileError Fabio.openimage(p; format = KCD())
    end
end

@testset "MPA" begin
    @testset "round-trip" begin
        A = Float64[i + 10j for i = 1:6, j = 1:4]
        p = joinpath(TMP, "rt.mpa")
        writempa(p, A)
        frame = Fabio.readimage(p)
        @test eltype(frame) === Float64
        @test size(frame) == (6, 4)
        @test collect(frame) == A
    end

    @testset "ADC2 is the fast axis" begin
        A = Float64[10i + j for i = 1:8, j = 1:3]       # size (8, 3)
        p = joinpath(TMP, "axes.mpa")
        writempa(p, A)
        h = Fabio.readheader(p)
        @test getheader(h, "ADC2_range", Int) == 8      # fast
        @test getheader(h, "ADC1_range", Int) == 3      # slow
        @test size(Fabio.readimage(p)) == (8, 3)
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "sections prefix their keys" begin
        p = joinpath(TMP, "sections.mpa")
        writempa(p, Float64[1 2; 3 4];
                 sections = Dict("CHN1" => Dict{String,Any}("caloff" => 0.5, "active" => 1)))
        h = Fabio.readheader(p)
        @test getheader(h, "CHN1_caloff", Float64) ≈ 0.5
        @test getheader(h, "CHN1_active", Int) == 1
        # A key outside any section keeps its bare name.
        @test h["mpafmt"] == "asc"
        @test startswith(h["DataMarker"], "[CDAT")
    end

    @testset "a file with no data marker is refused" begin
        p = joinpath(TMP, "nodata.mpa")
        write(p, Vector{UInt8}(codeunits("[ADC1]\nrange=2\n[ADC2]\nrange=2\nmpafmt=asc\n")))
        @test_throws Fabio.CorruptFileError Fabio.openimage(p)
    end

    @testset "a short value list is caught" begin
        p = joinpath(TMP, "short.mpa")
        write(p, Vector{UInt8}(codeunits("[ADC1]\nrange=4\n[ADC2]\nrange=4\n[CDAT0,16]\n1\n2\n3\n")))
        # The scan only reads the header; the shortfall shows up when the values are decoded.
        @test_throws Fabio.TruncatedFileError Fabio.readimage(p)
    end

    @testset "non-numeric values are reported" begin
        p = joinpath(TMP, "bad.mpa")
        write(p, Vector{UInt8}(codeunits("[ADC1]\nrange=2\n[ADC2]\nrange=2\n[CDAT0,4]\n1\n2\nx\n4\n")))
        @test_throws Fabio.CorruptFileError Fabio.readimage(p)
    end
end

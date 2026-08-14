@testset "Header" begin
    h = Header()
    h["Dim_1"] = "2048"
    h["ByteOrder"] = "LowByteFirst"
    h["ESRFCurrent"] = "198.099"

    @testset "ordering is preserved" begin
        @test collect(keys(h)) == ["Dim_1", "ByteOrder", "ESRFCurrent"]
    end

    @testset "values stay as recorded" begin
        # FabIO's documented contract: only the binary description is interpreted; everything
        # else is exposed exactly as it appears in the file.
        @test h["Dim_1"] === "2048"
        @test h["ESRFCurrent"] === "198.099"
    end

    @testset "typed accessors" begin
        @test getheader(h, "Dim_1", Int) === 2048
        @test getheader(h, "ESRFCurrent", Float64) === 198.099
        @test getheader(h, "ByteOrder", String) == "LowByteFirst"
        @test getheader(h, "Missing", Int, 7) === 7
        @test getheader(h, "ByteOrder", Int, -1) === -1
        @test_throws Fabio.CorruptFileError getheader(h, "Missing", Int)
        @test_throws Fabio.CorruptFileError getheader(h, "ByteOrder", Int)
    end

    @testset "case-insensitive lookup" begin
        # EDF producers disagree about capitalisation.
        @test getci(h, "dim_1") == "2048"
        @test getci(h, "DIM_1") == "2048"
        @test getheader(h, "byteorder", String) == "LowByteFirst"
        @test getci(h, "nope") === nothing
    end

    @testset "AbstractDict interface" begin
        @test length(h) == 3
        @test haskey(h, "Dim_1")
        @test !haskey(h, "Dim_9")
        @test get(h, "Dim_9", "fallback") == "fallback"
        @test sort(collect(keys(h))) == ["ByteOrder", "Dim_1", "ESRFCurrent"]
        h2 = copy(h)
        h2["extra"] = 1
        @test length(h) == 3 && length(h2) == 4
        delete!(h2, "extra")
        @test !haskey(h2, "extra")
    end

    @testset "merge keeps the newer value" begin
        base = Header(); base["a"] = "1"; base["b"] = "2"
        over = Header(); over["b"] = "99"
        merge!(base, over)
        @test base["a"] == "1"
        @test base["b"] == "99"
    end
end

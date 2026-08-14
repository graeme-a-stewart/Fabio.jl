# A complete out-of-tree format: one `scan` method plus a `register!` call. Nothing else.
struct ToyFormat <: Fabio.ImageFormat end

function Fabio.scan(::ToyFormat, src::Fabio.AbstractSource)
    h = Header()
    h["toy"] = true
    layout = BinaryLayout{Int16}(6, Base.filesize(src) - 6, (2, 2))
    return Header(), Fabio.FrameSpec[Fabio.FrameSpec(h, layout)]
end

@testset "registry and detection" begin
    @testset "defaults are registered" begin
        names = formatnames()
        @test :edf in names
        @test :esperanto in names
        @test :npy in names
    end

    @testset "magic matching honours offsets" begin
        head = Vector{UInt8}(codeunits("xxESPERANTO"))
        @test !matches(Magic("ESPERANTO"), head)
        @test matches(Magic("ESPERANTO", 2), head)
        @test !matches(Magic("ESPERANTO", 3), head)
        @test !matches(Magic("ESPERANTOOOOOOOOOOOO", 2), head)   # runs past the buffer
    end

    @testset "specific signatures outrank generic ones" begin
        # EDF's bare "{" must never shadow a format with a longer signature, regardless of
        # the order formats happened to be registered in.
        reg = formats()
        edfpos = findfirst(e -> e.name === :edf, reg)
        esppos = findfirst(e -> e.name === :esperanto, reg)
        npypos = findfirst(e -> e.name === :npy, reg)
        @test esppos < edfpos
        @test npypos < edfpos
    end

    @testset "an out-of-tree format is just scan + register!" begin
        toy = joinpath(TMP, "toy.toy")
        write(
            toy,
            vcat(Vector{UInt8}(codeunits("TOYFMT")), reinterpret(UInt8, Int16[1, 2, 3, 4])),
        )
        try
            register!(
                ToyFormat();
                name = :toy,
                description = "test-only format",
                extensions = ["toy"],
                magic = [Magic("TOYFMT")],
            )
            frame = Fabio.readimage(toy)
            @test eltype(frame) === Int16
            @test size(frame) == (2, 2)
            @test vec(frame) == Int16[1, 2, 3, 4]
            @test Fabio.pixeltype(toy) === Int16
        finally
            filter!(e -> e.name !== :toy, Fabio.REGISTRY)
        end
    end

    @testset "unknown formats are reported clearly" begin
        junk = joinpath(TMP, "junk.unknown")
        write(junk, UInt8[0xAB, 0xCD, 0xEF, 0x01, 0x02, 0x03, 0x04, 0x05])
        @test_throws Fabio.UnknownFormatError Fabio.openimage(junk)
    end

    @testset "extension is only a fallback" begin
        # An EDF file misnamed .npy must still be read as EDF, because magic wins.
        p = joinpath(TMP, "mislabelled.npy")
        writeedf(p, UInt16[1 2; 3 4])
        @test Fabio.openimage(f -> nameof(typeof(Fabio.imageformat(f))), p) === :EDF
    end
end

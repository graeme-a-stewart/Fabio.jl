# FileIO.jl registration, through the FabioFileIOExt package extension (DESIGN.md §10, §12).

using FileIO

_fpattern(::Type{T}, nx, ny) where {T} = T[T(x + 61 * y) for x = 1:nx, y = 1:ny]

@testset "FileIO registration" begin
    FDIR = mktempdir()
    A = _fpattern(UInt16, 14, 9)

    @testset "the extension registers Fabio's formats" begin
        registered = [String(k) for k in keys(FileIO.sym2info) if startswith(String(k), "FABIO_")]
        @test length(registered) >= 20
        for name in ("FABIO_EDF", "FABIO_CBF", "FABIO_MRC", "FABIO_ESPERANTO", "FABIO_MAR345")
            @test name in registered
        end
        # Names are prefixed, so they cannot collide with a format FileIO already defines.
        @test all(startswith("FABIO_"), registered)
    end

    @testset "formats FileIO already serves are left alone" begin
        # A user loading one of these through FileIO wants the ecosystem's answer, not ours.
        for (ext, expected) in ((".tif", :TIFF), (".npy", :NPY), (".h5", :HDF5))
            syms = FileIO.ext2sym[ext]
            names = syms isa Symbol ? [syms] : syms
            @test expected in names
            @test !any(s -> startswith(String(s), "FABIO_"), names)
        end
        # ... and Fabio has not claimed the netpbm extensions either.
        for ext in (".pgm", ".pbm")
            syms = FileIO.ext2sym[ext]
            names = syms isa Symbol ? [syms] : syms
            @test !any(s -> startswith(String(s), "FABIO_"), names)
        end
        # They are still perfectly readable through this package directly.
        p = joinpath(FDIR, "direct.pgm")
        Fabio.writeimage(p, A)
        @test collect(Fabio.readimage(p)) == A
    end

    @testset "save and load round trip" begin
        # extension => element type read back
        cases = [("edf", UInt16), ("cbf", UInt16), ("mrc", UInt16), ("sfrm", UInt16),
                 ("img", UInt16), ("ge", UInt16), ("spe", UInt16), ("mccd", UInt16),
                 ("f2d", Int32), ("kcd", Int32), ("mpa", Float64)]
        for (ext, T) in cases
            p = joinpath(FDIR, "rt.$ext")
            save(p, A)
            back = load(p)
            @test back isa Fabio.ImageFrame
            @test back isa AbstractArray{T,2}
            @test size(back) == size(A)
            @test collect(back) == T.(A)
        end
    end

    @testset "what load returns is a frame, not a bare array" begin
        h = Header()
        h["Title"] = "via FileIO"
        p = joinpath(FDIR, "hdr.edf")
        Fabio.writeimage(p, A; header = h)
        frame = load(p)
        @test frame isa Fabio.ImageFrame
        @test frame isa AbstractArray                 # so it drops into array code unchanged
        @test Fabio.getci(header(frame), "Title") == "via FileIO"
        @test mean(frame) == mean(A)
        @test Fabio.imageformat(frame) === Fabio.EDF()
    end

    @testset "detection is Fabio's, not FileIO's" begin
        # Three formats share the .img extension, which FileIO's flat table cannot express.
        # Routing every load through Fabio's own two-stage detection means the right one wins.
        p = joinpath(FDIR, "which.img")
        Fabio.writeimage(p, A; format = Fabio.Dtrek())
        frame = load(p)
        @test Fabio.imageformat(frame) === Fabio.Dtrek()
        @test collect(frame) == A
    end

    @testset "save accepts a frame as well as an array" begin
        frame = ImageFrame(A, Header(["Note" => "a frame"]))
        p = joinpath(FDIR, "fromframe.edf")
        save(p, frame)
        @test Fabio.getci(header(load(p)), "Note") == "a frame"
        @test collect(load(p)) == A
    end
end

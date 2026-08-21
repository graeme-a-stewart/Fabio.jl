# The generic write path: `writeimage`, format resolution, `coerce`, and the `writeformat`
# extension point. The per-format writers themselves are exercised by the reader testsets that
# use them to build fixtures; what is tested here is the layer above them.

using Fabio: writeimage, writeformat, canwrite, writableformats, writeformatforpath, writeone

_wpattern(::Type{T}, nx, ny, k = 0) where {T} =
    T[T(x + 61 * y + 1009 * k) for x = 1:nx, y = 1:ny]

@testset "writing" begin
    WDIR = mktempdir()

    @testset "the registry's writer flag is derived, not declared" begin
        # The README's standing complaint about FabIO is that its documented format table is
        # maintained by hand and has drifted from its code. The same trap applies here, so the
        # flag is computed from whether a `writeformat` method exists. This asserts it.
        for e in Fabio.formats()
            @test e.writer == canwrite(e.format)
        end
        @test Set(writableformats()) == Set([
            :bruker, :cbf, :dtrek, :edf, :fit2d, :fit2dmask, :ge, :kcd, :marccd,
            :mpa, :mrc, :npy, :pnm, :spe, :tiff,
        ])
        # Formats with no writer report so, and are not silently claimed.
        for name in (:esperanto, :hdf5, :mar345, :oxd, :raxis, :dm3, :xcalibur, :pilatus, :bruker100)
            @test !canwrite(Fabio.findformat(name).format)
        end
    end

    @testset "round trip through every writable format" begin
        A = _wpattern(UInt16, 16, 12)
        # extension => (element type read back, whether values survive unchanged)
        cases = [
            ("edf", UInt16, true), ("cbf", UInt16, true), ("npy", UInt16, true),
            ("tif", UInt16, true), ("mrc", UInt16, true), ("pgm", UInt16, true),
            ("sfrm", UInt16, true), ("img", UInt16, true), ("ge", UInt16, true),
            ("spe", UInt16, true), ("mccd", UInt16, true),
            ("f2d", Int32, true),      # Fit2D stores Int32; coerce narrows to it
            ("kcd", Int32, true),
            ("mpa", Float64, true),
            ("msk", UInt8, false),     # a mask keeps only which pixels were non-zero
        ]
        for (ext, T, exact) in cases
            p = joinpath(WDIR, "rt.$ext")
            @test writeimage(p, A) == p          # returns the path it wrote
            @test isfile(p)
            back = Fabio.readimage(p)
            @test eltype(back) === T
            @test size(back) == size(A)
            if exact
                @test collect(back) == A
            else
                @test collect(back) == UInt8.(A .!= 0)
            end
        end
    end

    @testset "what gets written" begin
        A = _wpattern(UInt16, 8, 6)
        h = Fabio.Header(); h["Title"] = "a scan"
        frame = ImageFrame(A, h)

        # A frame carries its header through.
        p = joinpath(WDIR, "frame.edf")
        writeimage(p, frame)
        @test Fabio.getci(header(Fabio.readimage(p)), "Title") == "a scan"

        # A bare array works, and takes the header keyword.
        p2 = joinpath(WDIR, "bare.edf")
        writeimage(p2, A; header = h)
        @test collect(Fabio.readimage(p2)) == A
        @test Fabio.getci(header(Fabio.readimage(p2)), "Title") == "a scan"

        # An explicit format overrides the extension, and rescues a path that has none.
        p3 = joinpath(WDIR, "noextension")
        writeimage(p3, frame; format = Fabio.EDF())
        @test collect(Fabio.readimage(p3; format = Fabio.EDF())) == A

        # Keyword arguments reach the format's own writer.
        p4 = joinpath(WDIR, "ascii.pgm")
        writeimage(p4, A; ascii = true)
        @test startswith(String(read(p4)[1:2]), "P2")     # plain, not the packed P5
        @test collect(Fabio.readimage(p4)) == A
    end

    @testset "multi-frame formats" begin
        frames = [_wpattern(UInt16, 10, 7, k) for k = 1:3]
        for ext in ("mrc", "ge", "spe", "tif")
            p = joinpath(WDIR, "stack.$ext")
            writeimage(p, frames)
            Fabio.openimage(p) do f
                @test length(f) == 3
                for k = 1:3
                    @test collect(f[k]) == frames[k]
                end
            end
        end
        # A single-frame format says so rather than dropping frames silently.
        @test_throws ArgumentError writeimage(joinpath(WDIR, "many.edf"), frames)
        @test_throws ArgumentError writeimage(joinpath(WDIR, "none.edf"), [])
    end

    @testset "coerce is in the write path" begin
        # A Fit2D mask is one bit per pixel, so any non-zero value becomes one.
        p = joinpath(WDIR, "mask.msk")
        writeimage(p, [0 5; 300 0])
        @test collect(Fabio.readimage(p)) == UInt8[0 1; 1 0]

        # Fit2D stores Int32, so an unsigned input is narrowed rather than rejected.
        p2 = joinpath(WDIR, "narrowed.f2d")
        writeimage(p2, _wpattern(UInt16, 8, 8))
        @test eltype(Fabio.readimage(p2)) === Int32

        # A float input to Fit2D keeps its fractional part as Float32.
        p3 = joinpath(WDIR, "float.f2d")
        writeimage(p3, Float64[1.5 2.5; 3.5 4.5])
        back = Fabio.readimage(p3)
        @test eltype(back) === Float32
        @test collect(back) == Float32[1.5 2.5; 3.5 4.5]

        # MarCCD rounds a float input to its unsigned 16-bit counts.
        p4 = joinpath(WDIR, "rounded.mccd")
        writeimage(p4, Float64[1.4 2.6; 3.5 4.5])
        @test eltype(Fabio.readimage(p4)) === UInt16
    end

    @testset "compression is symmetric with reading" begin
        A = _wpattern(UInt16, 12, 9)
        p = joinpath(WDIR, "zipped.edf.gz")
        writeimage(p, A)
        # Really gzip, not a plain file wearing the suffix.
        @test read(p)[1:2] == UInt8[0x1f, 0x8b]
        @test collect(Fabio.readimage(p)) == A
        # The formats the reader cannot decompress unaided are refused rather than mis-written.
        @test_throws Fabio.UnsupportedFormatError writeimage(joinpath(WDIR, "x.edf.bz2"), A)
        @test_throws Fabio.UnsupportedFormatError writeimage(joinpath(WDIR, "x.edf.xz"), A)
    end

    @testset "formats that cannot write say so" begin
        A = _wpattern(UInt16, 4, 4)
        # By extension...
        err = try
            writeimage(joinpath(WDIR, "x.esperanto"), A)
            nothing
        catch e
            e
        end
        @test err isa Fabio.UnsupportedFormatError
        @test occursin("esperanto", sprint(showerror, err)) ||
              occursin("writable", sprint(showerror, err))
        # ...and when named outright.
        err2 = try
            writeimage(joinpath(WDIR, "x.dat"), A; format = Fabio.Esperanto())
            nothing
        catch e
            e
        end
        @test err2 isa Fabio.UnsupportedFormatError
        @test occursin("Esperanto", sprint(showerror, err2))

        # An unknown extension, and no extension at all.
        @test_throws Fabio.UnsupportedFormatError writeimage(joinpath(WDIR, "x.zzz"), A)
        @test_throws ArgumentError writeimage(joinpath(WDIR, "plain"), A)
    end

    @testset "extension resolution prefers a format that can write" begin
        # .tif is registered to both Pilatus (higher priority, read-only) and plain TIFF.
        @test writeformatforpath("x.tif") === Fabio.TIFFLike{:plain}()
        # A compression suffix is looked through.
        @test writeformatforpath("x.edf.gz") === Fabio.EDF()
        @test writeformatforpath("X.EDF") === Fabio.EDF()
    end
end

@testset "convertimage" begin
    CDIR = mktempdir()
    A = _wpattern(UInt16, 12, 8)
    h = Fabio.Header()
    h["Title"] = "enstatite scan"
    h["ExposureTime"] = "1.5"

    src = joinpath(CDIR, "src.edf")
    writeimage(src, A; header = h)
    frame = Fabio.readimage(src)

    @testset "a frame knows the format it was read from" begin
        @test Fabio.imageformat(frame) === Fabio.EDF()
        # A frame built by hand has no format, and converting one is still fine.
        @test Fabio.imageformat(ImageFrame(A)) === nothing
        @test collect(Fabio.convertimage(ImageFrame(A), Fabio.EDF())) == A
    end

    @testset "layout keys are dropped, metadata is carried" begin
        @test haskey(header(frame), "Dim_1")          # the source describes its own layout
        conv = Fabio.convertimage(frame, Fabio.CBF())
        @test Fabio.imageformat(conv) === Fabio.CBF()
        # The EDF layout keys describe a file the CBF is not.
        for k in ("HeaderID", "ByteOrder", "DataType", "Dim_1", "Dim_2", "Size")
            @test !haskey(header(conv), k)
        end
        # The experiment metadata is what conversion exists to preserve.
        @test header(conv)["Title"] == "enstatite scan"
        @test header(conv)["ExposureTime"] == "1.5"
        @test collect(conv) == A
    end

    @testset "the documented TIFF to EDF conversion (DESIGN 16.3)" begin
        tif = joinpath(CDIR, "my.tiff")
        writeimage(tif, A)
        out = joinpath(CDIR, "my.edf")
        writeimage(out, Fabio.convertimage(Fabio.readimage(tif), Fabio.EDF()))
        @test collect(Fabio.readimage(out)) == A
    end

    @testset "metadata survives a CBF round trip" begin
        # writecbf used to emit `key value`, which is neither a CIF data name nor a comment,
        # so its own reader skipped it and the metadata was written but unreadable.
        p = joinpath(CDIR, "meta.cbf")
        writeimage(p, Fabio.convertimage(frame, Fabio.CBF()))
        back = Fabio.readimage(p)
        @test collect(back) == A
        @test Fabio.getci(header(back), "Title") == "enstatite scan"
        @test Fabio.getci(header(back), "ExposureTime") == "1.5"
    end

    @testset "coerce runs on the way through" begin
        conv = Fabio.convertimage(frame, Fabio.Fit2D())
        @test eltype(conv) === Int32
        @test collect(conv) == Int32.(A)
    end

    @testset "a stale layout key cannot override the real one" begin
        # The regression that motivated `layoutkeys`: writing a differently shaped array while
        # carrying a header from the source wrote Dim_1 twice, the reader took the last, and
        # the file was unreadable — a TruncatedFileError claiming 400 bytes for an 80-byte blob.
        small = A[1:8, 1:5]
        for (ext, fmt) in (("edf", Fabio.EDF()), ("img", Fabio.Dtrek()), ("sfrm", Fabio.Bruker{86}()))
            p = joinpath(CDIR, "stale.$ext")
            writeimage(p, small; header = header(frame), format = fmt)
            back = Fabio.readimage(p)
            @test size(back) == size(small)
            @test collect(back) == small
        end
        # And the keys appear once each, not twice.
        p = joinpath(CDIR, "once.edf")
        writeimage(p, small; header = header(frame))
        text = String(read(p))
        @test count(==("Dim_1"), [strip(first(split(l, '='))) for l in split(text, ';') if occursin('=', l)]) == 1
    end
end

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
        # A single-frame format says so rather than dropping frames silently. EDF is not one:
        # it is a sequence of independent blocks and writes as many as it is given.
        @test_throws ArgumentError writeimage(joinpath(WDIR, "many.cbf"), frames)
        @test_throws ArgumentError writeimage(joinpath(WDIR, "many.msk"), frames)
        @test_throws ArgumentError writeimage(joinpath(WDIR, "none.edf"), [])
        writeimage(joinpath(WDIR, "many.edf"), frames)
        @test Fabio.openimage(length, joinpath(WDIR, "many.edf")) == 3
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

@testset "the storage contract" begin
    # For every writable format and every element type, exactly one of three things must
    # happen, and the third is the point of the test:
    #
    #   1. the write succeeds and what `coerce` produced is what reads back, or
    #   2. it is refused with an UnsupportedFormatError naming the format,
    #
    # and never
    #
    #   3. a bare MethodError from a per-format writer two calls down, or a value silently
    #      reinterpreted as another type — a signed pixel read back unsigned, say.
    #
    # The invariant in (1) is `readimage(writeimage(A)) == coerce(fmt, A)`: coercion is what
    # decides the stored values, so it is what the file must contain.
    SDIR = mktempdir()
    alltypes = (UInt8, Int8, UInt16, Int16, UInt32, Int32, UInt64, Int64, Float32, Float64)

    for e in Fabio.formats()
        canwrite(e.format) || continue
        fmt = e.format
        stored = Fabio.storagetypes(fmt)
        @testset "$(e.name)" begin
            @test !isempty(stored)                    # a writable format declares what it holds
            for T in alltypes
                # Small positive values, so nothing is out of range for any format here; the
                # question is which types are accepted, not what clipping does.
                A = T[T(1) T(2); T(3) T(4)]
                p = joinpath(SDIR, "contract_$(e.name)_$T")
                local coerced
                try
                    coerced = Fabio.coerce(fmt, A)
                catch err
                    @test err isa Fabio.FabioError    # refusing in coerce is allowed
                    continue
                end
                ok = try
                    writeimage(p, A; format = fmt)
                    true
                catch err
                    # A refusal must be this package's own error, naming the format —
                    # never a MethodError leaking an internal function name.
                    @test err isa Fabio.UnsupportedFormatError
                    false
                end
                ok || continue

                back = Fabio.readimage(p; format = fmt)
                @test eltype(back) in stored
                @test collect(back) == coerced
                # A type the format stores outright is not retyped on the way in. The values
                # may still change: a Fit2D mask coerces by meaning, not by type, reducing
                # every non-zero pixel to a bit.
                T in stored && @test eltype(coerced) === T
            end
        end
    end
end

@testset "EDF, in depth" begin
    EDIR = mktempdir()
    _epat(k) = UInt16[UInt16(x + 61 * y + 1009 * k) for x = 1:7, y = 1:5]
    frames = [_epat(k) for k = 1:3]

    @testset "multi-frame" begin
        # EDF is a sequence of independent `{ header } data` blocks, so a multi-frame file is
        # simply several of them. The reader has always handled this; the writer used to
        # refuse, which was the largest asymmetry between the two.
        p = joinpath(EDIR, "multi.edf")
        writeimage(p, frames)
        Fabio.openimage(p) do f
            @test length(f) == 3
            for k = 1:3
                @test collect(f[k]) == frames[k]
                @test f[k].fileindex == k
            end
        end
        # The per-frame fields FabIO writes, and their 0-based numbering.
        h2 = Fabio.readheader(p; frame = 2)
        @test Fabio.getci(h2, "EDF_DataBlockID") == "1.Image.Psd"
        @test Fabio.getci(h2, "Image") == "1"
        @test Fabio.getci(h2, "HeaderID") == "EH:000001:000000:000000"

        # One frame is still one block.
        p1 = joinpath(EDIR, "one.edf")
        writeimage(p1, frames[1])
        @test length(collect(eachmatch(r"EDF_DataBlockID", String(read(p1))))) == 1
        @test collect(Fabio.readimage(p1)) == frames[1]

        @test_throws ArgumentError Fabio.writeedf(joinpath(EDIR, "none.edf"), Matrix{UInt16}[])
        @test_throws ArgumentError Fabio.writeedf(
            joinpath(EDIR, "mismatch.edf"), frames, [Header()])
    end

    @testset "compression" begin
        # The reader has always accepted Compression = Zlib/Gzip/Deflate; the writer can now
        # produce it. FabIO can read such files but cannot write them.
        p = joinpath(EDIR, "zlib.edf")
        writeimage(p, frames; compression = :zlib)
        Fabio.openimage(p) do f
            @test length(f) == 3
            for k = 1:3
                @test collect(f[k]) == frames[k]
            end
        end
        @test Fabio.getci(Fabio.readheader(p), "Compression") == "Zlib"
        # The recorded size is the *stored* size, which is what lets the reader find the next
        # block; getting this wrong is how a multi-frame compressed file loses its way.
        h = Fabio.readheader(p)
        @test parse(Int, Fabio.getci(h, "EDF_BinarySize")) < 7 * 5 * sizeof(UInt16) * 2

        # Real detector data compresses; the point of the option.
        flat = [fill(UInt16(7), 256, 256)]
        big, small = joinpath(EDIR, "flat.edf"), joinpath(EDIR, "flat_z.edf")
        writeimage(big, flat)
        writeimage(small, flat; compression = :zlib)
        @test filesize(small) < filesize(big) ÷ 10
        @test collect(Fabio.readimage(small)) == flat[1]

        @test_throws Fabio.UnsupportedFormatError writeimage(
            joinpath(EDIR, "bad.edf"), frames; compression = :lzma)
    end

    @testset "the header block describes itself truthfully" begin
        # EDF_HeaderSize states the size of the block it sits inside, which is circular: the
        # number's own width changes the block. It is written into a fixed-width field whose
        # value is computed from the lengths either side, so it must come out exact.
        for padto in (512, 1024), extra in (0, 40)
            h = Header()
            for i = 1:extra
                h["Key$i"] = "value $i"
            end
            p = joinpath(EDIR, "hdr_$(padto)_$(extra).edf")
            Fabio.writeedf(p, frames[1], h; padto = padto)
            raw = String(read(p))
            stated = parse(Int, Fabio.getci(Fabio.readheader(p), "EDF_HeaderSize"))
            actual = findfirst("}\n", raw)[end]
            @test stated == actual
            @test stated % padto == 0
            @test collect(Fabio.readimage(p)) == frames[1]
        end
    end

    @testset "a carried frame index does not duplicate" begin
        # The same trap layoutkeys exists for: EDF_DataBlockID and Image are generated per
        # frame, so a header carried from frame 3 must not describe the file it lands in.
        src = joinpath(EDIR, "carry_src.edf")
        writeimage(src, frames)
        third = Fabio.readimage(src; frame = 3)
        @test Fabio.getci(header(third), "EDF_DataBlockID") == "2.Image.Psd"
        dst = joinpath(EDIR, "carry_dst.edf")
        writeimage(dst, third)
        raw = String(read(dst))
        @test length(collect(eachmatch(r"EDF_DataBlockID", raw))) == 1
        @test Fabio.getci(Fabio.readheader(dst), "EDF_DataBlockID") == "0.Image.Psd"
        @test collect(Fabio.readimage(dst)) == frames[3]
    end
end

@testset "MD5" begin
    # RFC 1321 section A.5's own test suite. The last one is 80 bytes, which crosses a block
    # boundary, and the first is empty, which is entirely padding — the two cases a hand-rolled
    # digest gets wrong.
    vectors = [
        ("", "d41d8cd98f00b204e9800998ecf8427e"),
        ("a", "0cc175b9c0f1b6a831c399e269772661"),
        ("abc", "900150983cd24fb0d6963f7d28e17f72"),
        ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
        ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
         "d174ab98d277d9f5a5611c2c9f419d9f"),
        ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
         "57edf4a22be3c955ac49da2e2107b67a"),
    ]
    for (input, want) in vectors
        @test Fabio.md5hex(input) == want
    end
    # Every length across a block boundary, so the padding arithmetic is exercised at each
    # offset rather than only at the two the RFC happens to cover.
    for n in 0:130
        @test length(Fabio.md5(rand(UInt8, n))) == 16
    end
    @test Fabio.md5base64("abc") == "kAFQmDzST7DWlj99KOF/cg=="
end

@testset "CBF, in depth" begin
    CBDIR = mktempdir()
    A = Int32[Int32(3x + 7y) for x = 1:9, y = 1:6]
    h = Header()
    h["Title"] = "a scan"
    h["Exposure_time"] = "0.5 s"
    h["Wavelength"] = "1.0332 A"

    @testset "the free-form header lives in a CIF value, and is read back out" begin
        # Detectors, and FabIO, keep a CBF's header inside `_array_data.header_contents` as a
        # block of `# key value` lines. FabIO reports that block as one opaque string, so a
        # Pilatus CBF's exposure time is in the file but not reachable as a header entry.
        p = joinpath(CBDIR, "meta.cbf")
        writeimage(p, A; header = h)
        raw = String(read(p))
        @test occursin("_array_data.header_contents", raw)
        @test occursin("# Title a scan", raw)

        back = Fabio.readimage(p)
        @test collect(back) == A
        @test Fabio.getci(header(back), "Title") == "a scan"
        @test Fabio.getci(header(back), "Exposure_time") == "0.5 s"
        # The raw block is kept alongside the keys taken out of it.
        @test occursin("# Title a scan", Fabio.getci(header(back), "_array_data.header_contents"))

        # Which is what makes the normalised metadata layer work on a CBF at all.
        m = Fabio.normalise(back)
        @test m.exposure_time == 0.5
        @test m.wavelength ≈ 1.0332e-10
    end

    @testset "a CIF text field spanning lines" begin
        # `_name` alone on a line, value between two semicolons. The parser had no notion of
        # this, so a header written the way the format specifies read back empty.
        p = joinpath(CBDIR, "textfield.cbf")
        writeimage(p, A; header = h)
        got = Fabio.getci(Fabio.readheader(p), "_array_data.header_contents")
        @test got !== nothing
        @test count(l -> startswith(strip(l), "#"), split(got, ['\n', '\r'])) == 3
    end

    @testset "Content-MD5 and padding" begin
        p = joinpath(CBDIR, "digest.cbf")
        writeimage(p, A)
        hh = Fabio.readheader(p)
        @test Fabio.getci(hh, "Content-MD5") !== nothing
        @test Fabio.getci(hh, "X-Binary-Size-Padding") == "1"
        @test Fabio.verifychecksum(p) === true

        # Flipping one byte of the compressed blob is caught without decoding it.
        raw = read(p)
        i = findfirst(==(0xD5), raw)
        raw[i+10] = xor(raw[i+10], 0xFF)
        bad = joinpath(CBDIR, "corrupt.cbf")
        write(bad, raw)
        @test Fabio.verifychecksum(bad) === false

        # A file with no digest is legal, and says so rather than failing.
        nodigest = joinpath(CBDIR, "nodigest.cbf")
        write(nodigest, replace(String(read(p)), r"Content-MD5:[^\n]*\n" => ""))
        @test Fabio.verifychecksum(nodigest) === missing
        @test collect(Fabio.readimage(nodigest)) == A

        # Padding is written and skipped over.
        for pad in (0, 1, 7)
            q = joinpath(CBDIR, "pad$pad.cbf")
            Fabio.writecbf(q, A, Header(); padding = pad)
            @test Fabio.getci(Fabio.readheader(q), "X-Binary-Size-Padding") == string(pad)
            @test collect(Fabio.readimage(q)) == A
            @test Fabio.verifychecksum(q) === true
        end
        @test_throws ArgumentError Fabio.writecbf(joinpath(CBDIR, "neg.cbf"), A, Header(); padding = -1)

        @test_throws ArgumentError Fabio.verifychecksum(
            (Fabio.writeimage(joinpath(CBDIR, "notcbf.edf"), A); joinpath(CBDIR, "notcbf.edf")))
    end
end

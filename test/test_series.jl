# Filename arithmetic, and series spanning several files (DESIGN.md §4.2, §16.5–16.7).
#
# The filename cases are the ones FabIO's own `FilenameObject` was checked against, and this
# package agrees with it on every one of them — including Bruker's `scan.0001`, where the
# extension is the number, and names carrying a compression suffix.

using Fabio: splitfilenumber, filenumber, nextfile, prevfile, jumpfile, seriespaths,
             open_series, seriesfiles, framesperfile, writeimage

_spattern(::Type{T}, nx, ny, k = 0) where {T} =
    T[T(x + 61 * y + 1009 * k) for x = 1:nx, y = 1:ny]

@testset "file series" begin
    SDIR = mktempdir()

    @testset "filename arithmetic" begin
        # name => (number, digits, next). Compared against FabIO's next_filename on each.
        cases = [
            ("200mMmgso4_001.mar2300", 1, 3, "200mMmgso4_002.mar2300"),
            ("foobar_0000.edf", 0, 4, "foobar_0001.edf"),
            ("img_0999.cbf", 999, 4, "img_1000.cbf"),
            ("scan.0001", 1, 4, "scan.0002"),              # Bruker: the extension is the number
            ("data_12.ge3", 12, 2, "data_13.ge3"),
            ("a_1_2.edf", 2, 1, "a_1_3.edf"),              # the *last* run of digits wins
            ("x_0001.edf.gz", 1, 4, "x_0002.edf.gz"),      # through a compression suffix
            ("ff_0001.mar2300.gz", 1, 4, "ff_0002.mar2300.gz"),
            # Two stacked format extensions: the digits in "mar2300" are the detector name,
            # not the sequence number, and only the registry separates them.
            ("200mMmgso4_001.mar2300.edf", 1, 3, "200mMmgso4_002.mar2300.edf"),
        ]
        for (name, num, digits, nxt) in cases
            prefix, n, d, suffix = splitfilenumber(name)
            @test n == num
            @test d == digits
            # The split is lossless.
            @test prefix * lpad(string(n), d, '0') * suffix == name
            @test filenumber(name) == num
            @test nextfile(name) == nxt
        end

        # Directories are preserved.
        @test nextfile(joinpath("sub", "dir", "img_0007.cbf")) ==
              joinpath("sub", "dir", "img_0008.cbf")

        @test prevfile("img_0008.cbf") == "img_0007.cbf"
        @test jumpfile("200mMmgso4_001.mar2300", 12) == "200mMmgso4_012.mar2300"
        @test jumpfile("img_0007.cbf", 1234) == "img_1234.cbf"   # padding gives way to the number

        # A name with no number cannot be counted from; FabIO raises here too.
        @test filenumber("plain.edf") === nothing
        @test_throws ArgumentError nextfile("plain.edf")
        @test_throws ArgumentError prevfile("plain.edf")
        @test_throws ArgumentError jumpfile("plain.edf", 3)
        # FabIO answers `img_-001.edf` for the file before the first, which cannot exist.
        @test_throws ArgumentError prevfile("img_0000.edf")
    end

    @testset "enumerating a series" begin
        for i = 1:6
            writeimage(joinpath(SDIR, "scan_" * lpad(i, 4, '0') * ".edf"), _spattern(UInt16, 10, 8, i))
        end
        firstpath = joinpath(SDIR, "scan_0001.edf")

        # With no bound, the series runs until a file is missing.
        @test length(seriespaths(firstpath)) == 6
        @test basename.(seriespaths(firstpath; count = 3)) ==
              ["scan_0001.edf", "scan_0002.edf", "scan_0003.edf"]
        @test length(seriespaths(firstpath; last = joinpath(SDIR, "scan_0004.edf"))) == 4
        @test basename.(seriespaths(firstpath; last = joinpath(SDIR, "scan_0005.edf"), step = 2)) ==
              ["scan_0001.edf", "scan_0003.edf", "scan_0005.edf"]
        @test_throws ArgumentError seriespaths(firstpath; step = 0)
    end

    @testset "single-frame files, one frame each" begin
        firstpath = joinpath(SDIR, "scan_0001.edf")
        open_series(first = firstpath) do s
            @test length(s) == 6
            @test framesperfile(s) == fill(1, 6)
            @test length(seriesfiles(s)) == 6
            for i = 1:6
                @test collect(s[i]) == _spattern(UInt16, 10, 8, i)
                @test s[i].seriesindex == i
                @test s[i].fileindex == 1
                @test basename(s[i].source) == "scan_" * lpad(i, 4, '0') * ".edf"
            end
            # §16.6: random access, out of order.
            @test collect(s[5]) == _spattern(UInt16, 10, 8, 5)
            @test collect(s[2]) == _spattern(UInt16, 10, 8, 2)
            @test collect(s[6]) == _spattern(UInt16, 10, 8, 6)
            # Iteration agrees with indexing.
            @test [collect(f) for f in s] == [collect(s[i]) for i = 1:6]
            @test_throws BoundsError s[7]
            @test_throws BoundsError s[0]
        end
    end

    @testset "multi-frame files, counted across the boundary" begin
        for i = 1:3
            writeimage(
                joinpath(SDIR, "stack_" * lpad(i, 3, '0') * ".mrc"),
                [_spattern(UInt16, 6, 5, 10i + k) for k = 1:4],
            )
        end
        open_series(first = joinpath(SDIR, "stack_001.mrc")) do s
            @test length(s) == 12                 # 3 files x 4 frames, indexed as one sequence
            @test framesperfile(s) == [4, 4, 4]
            # Frame 6 is the second frame of the second file.
            f = s[6]
            @test basename(f.source) == "stack_002.mrc"
            @test f.fileindex == 2
            @test f.seriesindex == 6
            @test collect(f) == _spattern(UInt16, 6, 5, 22)
            # Every frame lands where it should.
            for (i, k) in enumerate([10i + k for i = 1:3 for k = 1:4])
                @test collect(s[i]) == _spattern(UInt16, 6, 5, k)
            end
        end
    end

    @testset "explicit paths, and closing" begin
        s = open_series([
            joinpath(SDIR, "scan_0002.edf"),
            joinpath(SDIR, "scan_0005.edf"),
        ])
        @test length(s) == 2
        @test collect(s[1]) == _spattern(UInt16, 10, 8, 2)
        @test collect(s[2]) == _spattern(UInt16, 10, 8, 5)
        @test occursin("2 frames across 2 files", sprint(show, MIME"text/plain"(), s))
        close(s)
        @test_throws ArgumentError s[1]
        close(s)                                   # closing twice is not an error
        @test_throws ArgumentError open_series(String[])
        @test_throws ArgumentError open_series([joinpath(SDIR, "no_such_file_0001.edf")])
    end

    @testset "a frame outlives the file it came from" begin
        # The series keeps one file open and closes it when the index moves on. A frame taken
        # before that must stay readable: a memory-mapped frame holds its mapping through the
        # array, not through the file handle.
        s = open_series(first = joinpath(SDIR, "scan_0001.edf"))
        f1 = s[1]
        @test !(parent(f1) isa Array)               # it really is a view, not a copy
        for i = 2:6
            s[i]
        end
        @test collect(f1) == _spattern(UInt16, 10, 8, 1)
        GC.gc()
        @test collect(f1) == _spattern(UInt16, 10, 8, 1)
        close(s)
        @test collect(f1) == _spattern(UInt16, 10, 8, 1)
    end
end

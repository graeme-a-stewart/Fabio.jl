# The command-line converter (DESIGN.md §16.11), after FabIO's `fabio-convert`.
#
# `main` takes its output streams as keyword arguments and returns an exit code rather than
# calling `exit`, which is what makes it testable in process. The exit codes are FabIO's:
# 0 success, 1 a conversion failed, 2 bad arguments.

_cpattern(::Type{T}, nx, ny, k = 0) where {T} =
    T[T(x + 61 * y + 1009 * k) for x = 1:nx, y = 1:ny]

"""Run the CLI, capturing both streams."""
function _runcli(args...)
    out, err = IOBuffer(), IOBuffer()
    code = Fabio.main(collect(String, args); stdout = out, stderr = err)
    return (code = code, out = String(take!(out)), err = String(take!(err)))
end

@testset "command-line converter" begin
    CDIR = mktempdir()
    A = _cpattern(UInt16, 8, 6)
    for i = 1:3
        Fabio.writeimage(joinpath(CDIR, "frame_" * lpad(i, 3, '0') * ".cbf"), _cpattern(UInt16, 8, 6, i))
    end
    src1 = joinpath(CDIR, "frame_001.cbf")

    @testset "informational options" begin
        r = _runcli("--help")
        @test r.code == 0
        @test occursin("usage: fabio-convert", r.out)
        @test _runcli("-h").code == 0

        r = _runcli("--version")
        @test r.code == 0
        @test occursin("Fabio.jl", r.out)

        r = _runcli("--list")
        @test r.code == 0
        for name in ("edf", "cbf", "esperanto", "mar345")
            @test occursin(name, r.out)
        end
        # The table distinguishes what can be written from what can only be read.
        @test occursin("rw", r.out)
        @test occursin(r"esperanto\s+r\s", r.out)
    end

    @testset "argument errors all return 2" begin
        @test _runcli().code == 2                                  # no inputs
        @test _runcli(src1).code == 2                              # no output format
        @test _runcli("-F", "nosuchformat", src1).code == 2
        @test _runcli("--frobnicate", src1).code == 2              # unknown option
        @test _runcli("-F").code == 2                              # option missing its value
        @test _runcli("-o").code == 2

        # A format that can be read but not written says so, and names the alternatives.
        r = _runcli("-F", "esperanto", src1)
        @test r.code == 2
        @test occursin("read but not written", r.err)
        @test occursin("edf", r.err)

        # Unknown formats point at --list.
        @test occursin("--list", _runcli("-F", "nosuchformat", src1).err)
    end

    @testset "converting" begin
        r = _runcli("-F", "edf", "-v", src1)
        @test r.code == 0
        @test occursin("convert", r.out)
        out1 = joinpath(CDIR, "frame_001.edf")
        @test isfile(out1)
        @test collect(Fabio.readimage(out1)) == _cpattern(UInt16, 8, 6, 1)

        # Several inputs at once.
        r = _runcli("-F", "mrc", joinpath(CDIR, "frame_001.cbf"),
                    joinpath(CDIR, "frame_002.cbf"), joinpath(CDIR, "frame_003.cbf"))
        @test r.code == 0
        for i = 1:3
            p = joinpath(CDIR, "frame_" * lpad(i, 3, '0') * ".mrc")
            @test isfile(p)
            @test collect(Fabio.readimage(p)) == _cpattern(UInt16, 8, 6, i)
        end
    end

    @testset "output placement" begin
        # A directory that does not exist yet is created.
        dir = joinpath(CDIR, "out")
        r = _runcli("-F", "edf", "-o", dir, joinpath(CDIR, "frame_001.cbf"),
                    joinpath(CDIR, "frame_002.cbf"))
        @test r.code == 0
        @test isdir(dir)
        @test isfile(joinpath(dir, "frame_001.edf"))
        @test isfile(joinpath(dir, "frame_002.edf"))

        # A single input with -o naming a file, with no extension to infer from: the format
        # was given outright, so it does not need inferring.
        named = joinpath(CDIR, "named_output")
        r = _runcli("-F", "mrc", "-o", named, src1)
        @test r.code == 0
        @test isfile(named)
        @test collect(Fabio.readimage(named; format = Fabio.MRC())) == _cpattern(UInt16, 8, 6, 1)
    end

    @testset "existing destinations" begin
        p = joinpath(CDIR, "clobber.cbf")
        Fabio.writeimage(p, A)
        dst = joinpath(CDIR, "clobber.edf")

        @test _runcli("-F", "edf", p).code == 0
        @test isfile(dst)

        # Refusing to overwrite is a failure, not an argument error.
        r = _runcli("-F", "edf", p)
        @test r.code == 1
        @test occursin("exists", r.err)

        @test _runcli("-F", "edf", "-f", p).code == 0            # --force overwrites
        r = _runcli("-F", "edf", "-n", "-v", p)                  # --no-clobber skips quietly
        @test r.code == 0
        @test occursin("skip", r.out)

        r = _runcli("-F", "edf", "-u", "-v", p)                  # --update: already current
        @test r.code == 0
        @test occursin("up to date", r.out)

        # A dry run reports and changes nothing — including over an existing destination,
        # where it must not fail merely because a file is in the way.
        gone = joinpath(CDIR, "notyet.edf")
        r = _runcli("-F", "edf", "--dry-run", "-o", gone, p)
        @test r.code == 0
        @test occursin("would convert", r.out)
        @test !isfile(gone)
        r = _runcli("-F", "edf", "--dry-run", p)
        @test r.code == 0
        @test occursin("destination exists", r.out)
    end

    @testset "a bad input is a failure, not a crash" begin
        junk = joinpath(CDIR, "junk.cbf")
        write(junk, "not a CBF file at all")
        r = _runcli("-F", "edf", junk)
        @test r.code == 1
        @test occursin("junk.cbf", r.err)
        # ... and the other files in the same run still convert.
        r = _runcli("-F", "edf", "-f", junk, joinpath(CDIR, "frame_003.cbf"))
        @test r.code == 1
        @test isfile(joinpath(CDIR, "frame_003.edf"))
    end

    @testset "multi-frame sources keep every frame" begin
        stack = joinpath(CDIR, "stack.mrc")
        Fabio.writeimage(stack, [_cpattern(UInt16, 6, 5, k) for k = 1:4])
        r = _runcli("-F", "spe", stack)
        @test r.code == 0
        Fabio.openimage(joinpath(CDIR, "stack.spe")) do f
            @test length(f) == 4
            for k = 1:4
                @test collect(f[k]) == _cpattern(UInt16, 6, 5, k)
            end
        end
    end

    @testset "a closed pipe is not a failure" begin
        # `fabio-convert --list | head` closes the pipe early. Testing the real thing needs a
        # subprocess; what is checked here is the predicate that keeps it from being reported
        # as a crash, since the alternative is a Julia stack trace in a shell pipeline.
        @test Fabio._isbrokenpipe(Base.IOError("write: broken pipe", Base.UV_EPIPE))
        @test !Fabio._isbrokenpipe(Base.IOError("write: other", Base.UV_EACCES))
        @test !Fabio._isbrokenpipe(ArgumentError("unrelated"))
    end

    @testset "-- ends the options" begin
        odd = joinpath(CDIR, "-starts-with-a-dash.cbf")
        Fabio.writeimage(odd, A)
        r = _runcli("-F", "edf", "--", odd)
        @test r.code == 0
        @test isfile(joinpath(CDIR, "-starts-with-a-dash.edf"))
    end
end

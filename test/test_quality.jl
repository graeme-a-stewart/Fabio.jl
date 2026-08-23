# Package-quality checks: Aqua for the things a package can get structurally wrong, JET for
# the things a call can get wrong before it is ever run.
#
# These are the two `DESIGN.md` §14 named and neither had been run until now.

using Aqua
using JET

@testset "package quality" begin
    @testset "Aqua" begin
        # The full battery, ambiguities and compat bounds included. `deps_compat` was the one
        # that found something: Base64, Dates and Mmap had no [compat] entry, nor did any of
        # the test-only dependencies, which is enough to keep a package out of the General
        # registry.
        Aqua.test_all(Fabio)
    end

    @testset "JET" begin
        # JET reaches into Julia's compiler internals and refuses to run at all on a
        # prerelease, saying so and pointing at a JET_DEV_MODE preference. Nightly is in the
        # CI matrix, so the analysis is skipped there rather than failing the build over a
        # tool that has declined to work.
        if !isempty(VERSION.prerelease)
            @info "Skipping JET on a prerelease Julia" version = VERSION
            @test true
            return
        end
        # Whole-package analysis is deliberately *not* asserted here. `JET.report_package`
        # returns 43 reports on this package and every one examined is a false positive of the
        # same two kinds:
        #
        #   - a `Union{Nothing,T}` the code has already correlated away, as in
        #     `occursin('=', line) && ... findfirst('=', line)`, where JET cannot see that the
        #     guard makes the `nothing` unreachable; and
        #   - Base's generic container constructors explored for argument types that never
        #     arrive, reached through a `convert` on a declared type such as
        #     `local specs::Vector{FrameSpec}` in `_openimage` — an annotation that is a real
        #     contract check for out-of-tree `scan` methods and is not worth removing to quiet
        #     an analyser exploring paths that cannot be taken.
        #
        # Asserting a report count instead would be a number to update, not a test. What is
        # asserted is that the entry points which *are* clean stay clean, which is where a
        # genuine regression — an unguarded `nothing`, a real dispatch failure — would show.
        QDIR = mktempdir()
        A = UInt16[UInt16(x + 61 * y) for x = 1:16, y = 1:12]
        I32 = Int32.(A)

        @test_call Fabio.writeimage(joinpath(QDIR, "a.edf"), A)
        @test_call Fabio.writeimage(joinpath(QDIR, "a.cbf"), I32)
        @test_call Fabio.writeimage(joinpath(QDIR, "a.tif"), A)
        @test_call Fabio.writeimage(joinpath(QDIR, "a.mrc"), A)
        @test_call Fabio.writeimage(joinpath(QDIR, "a.npy"), A)

        @test_call Fabio.md5base64(UInt8[1, 2, 3])
        @test_call Fabio.nextfile("img_0001.edf")
        @test_call Fabio.splitfilenumber("img_0001.edf")
        @test_call Fabio.coerce(Fabio.TIFFLike{:marccd}(), A)
        @test_call Fabio.narrowstorage(Fabio.PNM(), A)
        @test_call Fabio.storagetypes(Fabio.EDF())
        @test_call Fabio.writableformats()
    end
end

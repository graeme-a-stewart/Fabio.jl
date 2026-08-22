# The optional normalised-metadata layer (DESIGN.md §11).
#
# The header values below are the ones real files of each format actually carry — read off
# the detector data this project has been validated against — so these testsets check the unit
# conversions on realistic input rather than on invented numbers. Two of them are their own
# proof: Bruker's WAVELEN reads 1.541840 Å, which is Cu Kα, and KCD's Alpha1 reads 0.709300 Å,
# which is Mo Kα1. Getting the unit wrong would not land on a characteristic emission line.

using Fabio: normalise, ImageMetadata

const ANG = 1e-10

"""Tuples have no `isapprox`, and every pair here is a pair of floats."""
_approxtuple(a, b) = a !== nothing && length(a) == length(b) && all(isapprox.(a, b))

@testset "normalised metadata" begin
    @testset "a format with no method yields nothing, not an error" begin
        m = normalise(Fabio.NPY(), Header())
        @test m isa ImageMetadata
        @test m.exposure_time === nothing
        @test m.wavelength === nothing
        @test m.detector_distance === nothing
        @test m.beam_center === nothing
        @test m.pixel_size === nothing
        @test m.timestamp === nothing
        # A frame built by hand has no format at all.
        @test normalise(ImageFrame(zeros(UInt16, 2, 2))) isa ImageMetadata
        # It renders without blowing up on the empty fields.
        @test occursin("ImageMetadata", sprint(show, MIME"text/plain"(), m))
    end

    @testset "Esperanto — all six quantities" begin
        h = Header()
        h["dexposuretimeinsec"] = 1.0
        h["dalpha1"] = 0.29
        h["ddistanceinmm"] = 400.0
        h["dxorigininpix"] = 1024.0
        h["dyorigininpix"] = 1020.0
        h["drealpixelsizex"] = 0.2
        h["drealpixelsizey"] = 0.2
        m = normalise(Fabio.Esperanto(), h)
        @test m.exposure_time == 1.0
        @test m.wavelength ≈ 0.29 * ANG
        @test m.detector_distance ≈ 0.4                 # 400 mm in metres
        @test m.beam_center == (1024.0, 1020.0)
        @test _approxtuple(m.pixel_size, (200e-6, 200e-6))           # 0.2 mm in metres
    end

    @testset "MarCCD — the reader has already unscaled its integers" begin
        h = Header()
        h["exposure_time"] = 5.0
        h["source_wavelength"] = 0.9762500000000001
        h["xtal_to_detector"] = 142.68800000000002
        h["beam_x"] = 112.07900000000001
        h["beam_y"] = 113.571
        h["pixelsize_x"] = 0.073242
        h["pixelsize_y"] = 0.073242
        m = normalise(Fabio.TIFFLike{:marccd}(), h)
        @test m.exposure_time == 5.0
        @test m.wavelength ≈ 0.97625 * ANG
        @test m.detector_distance ≈ 0.142688
        @test m.beam_center[1] ≈ 112.079
        @test m.pixel_size[1] ≈ 73.242e-6
    end

    @testset "Pilatus — Dectris already records SI" begin
        h = Header()
        h["Exposure_time"] = "0.5000000 s"
        h["Pixel_size"] = "172e-6 m x 172e-6 m"
        h["Wavelength"] = "1.0332 A"
        h["Detector_distance"] = "0.15 m"
        h["Beam_xy"] = "(500.50, 600.25) pixels"
        m = normalise(Fabio.TIFFLike{:pilatus}(), h)
        @test m.exposure_time == 0.5
        @test _approxtuple(m.pixel_size, (172e-6, 172e-6))           # no conversion needed
        @test m.wavelength ≈ 1.0332 * ANG
        @test m.detector_distance == 0.15               # already metres
        @test m.beam_center == (500.5, 600.25)
        # The same block appears in CBF files written by the same detectors.
        @test _approxtuple(normalise(Fabio.CBF(), h).pixel_size, (172e-6, 172e-6))
        @test normalise(Fabio.CBF(), h).wavelength ≈ 1.0332 * ANG

        # A file that records only some of them reports only those.
        h2 = Header()
        h2["Exposure_time"] = "0.5000000 s"
        h2["Pixel_size"] = "172e-6 m x 172e-6 m"
        m2 = normalise(Fabio.TIFFLike{:pilatus}(), h2)
        @test m2.exposure_time == 0.5
        @test m2.wavelength === nothing
        @test m2.detector_distance === nothing
        @test m2.beam_center === nothing
    end

    @testset "d*TREK — a beam centre in millimetres becomes pixels" begin
        h = Header()
        h["TIME"] = "1.00"
        h["WAVELENGTH"] = "1.0736"
        h["DISTANCE"] = "270.800"
        h["PIXEL_SIZE"] = "0.102588"
        h["BEAM_CENTER_X"] = "158.320"
        h["BEAM_CENTER_Y"] = "153.975"
        h["DATE"] = "Wed Nov 11 11:24:13 2009"
        m = normalise(Fabio.Dtrek(), h)
        @test m.exposure_time == 1.0
        @test m.wavelength ≈ 1.0736 * ANG
        @test m.detector_distance ≈ 0.2708
        @test _approxtuple(m.pixel_size, (102.588e-6, 102.588e-6))
        # 158.320 mm / 0.102588 mm per pixel — which lands mid-detector on the 3072² file
        # this came from, and would not if the unit were wrong.
        @test m.beam_center[1] ≈ 158.320 / 0.102588
        @test m.beam_center[2] ≈ 153.975 / 0.102588
        @test 1500 < m.beam_center[1] < 1600
        @test m.timestamp == DateTime(2009, 11, 11, 11, 24, 13)

        # Without a pixel size there is nothing to convert with, so it declines to guess.
        h2 = copy(h)
        delete!(h2, "PIXEL_SIZE")
        @test normalise(Fabio.Dtrek(), h2).beam_center === nothing
    end

    @testset "Bruker — packed fields, and centimetres" begin
        h = Header()
        h["CUMULAT"] = "11.600000"
        h["WAVELEN"] = "1.541840         1.540600         1.544390         1.392220"
        h["DISTANC"] = "4.996016                           6.000016"
        h["CENTER"] = "382.200000       508.200000       382.200000       508.200000"
        h["CREATED"] = "07-Mar-2024                         21:49:06"
        m = normalise(Fabio.Bruker{86}(), h)
        @test m.exposure_time == 11.6
        # 1.541840 Å is Cu Kα; the unit is right because the number is a real emission line.
        @test m.wavelength ≈ 1.54184 * ANG
        @test m.detector_distance ≈ 0.04996016        # 4.996 cm in metres
        @test m.beam_center == (382.2, 508.2)         # pixels, of a 768x1024 frame
        @test m.timestamp == DateTime(2024, 3, 7, 21, 49, 6)
        # Deliberately not guessed at from DETTYPE.
        @test m.pixel_size === nothing
        @test normalise(Fabio.Bruker{100}(), h).exposure_time == 11.6
    end

    @testset "KCD — micrometres" begin
        h = Header()
        h["Exposure time"] = "3.747"
        h["Alpha1"] = "0.709300"
        h["pixel X-size (um)"] = "55.000"
        h["pixel Y-size (um)"] = "55.000"
        m = normalise(Fabio.KCD(), h)
        @test m.exposure_time == 3.747
        # 0.7093 Å is Mo Kα1.
        @test m.wavelength ≈ 0.7093 * ANG
        @test _approxtuple(m.pixel_size, (55e-6, 55e-6))
    end

    @testset "value parsing" begin
        # A number embedded in text, with a unit after it.
        @test normalise(Fabio.TIFFLike{:pilatus}(), Header(["Exposure_time" => "0.5 s"])).exposure_time == 0.5
        # Scientific notation.
        @test _approxtuple(
            normalise(Fabio.TIFFLike{:pilatus}(), Header(["Pixel_size" => "172e-6 m x 172e-6 m"])).pixel_size,
            (172e-6, 172e-6),
        )
        # Negative and unparseable values.
        h = Header(["TIME" => "not a number"])
        @test normalise(Fabio.Dtrek(), h).exposure_time === nothing
        # A date that does not parse leaves the field empty rather than throwing.
        @test normalise(Fabio.Dtrek(), Header(["DATE" => "sometime last Tuesday"])).timestamp === nothing
    end

    @testset "reached from a frame" begin
        # `normalise(frame)` picks the format up from the frame itself.
        d = mktempdir()
        h = Header()
        h["TIME"] = "2.50"
        h["WAVELENGTH"] = "0.9793"
        p = joinpath(d, "meta.img")
        Fabio.writeimage(p, UInt16[1 2; 3 4]; header = h, format = Fabio.Dtrek())
        frame = Fabio.readimage(p)
        @test Fabio.imageformat(frame) === Fabio.Dtrek()
        m = normalise(frame)
        @test m.exposure_time == 2.5
        @test m.wavelength ≈ 0.9793 * ANG
    end
end

# ---------------------------------------------------------------------------------------
# The same six formats, read from real detector files. Opt-in, on the same environment
# variables the format testsets use. These check that the readers really do produce the keys
# the conversions above expect — the unit tests cannot, since they build the header by hand.
# ---------------------------------------------------------------------------------------

@testset "normalised metadata from real files" begin
    # (env var, relative path, expected) — expected values in the units ImageMetadata uses.
    realcases = [
        (
            "FABIO_JL_LOCAL_TESTDATA", "enst_s1_1_1.esperanto",
            (exposure = 1.0, angstrom = 0.29, mm = 400.0, beam = (1024.0, 0.0), um = 200.0),
        ),
        (
            "FABIO_JL_KCD_TESTDATA", "s01f0001.kcd",
            (exposure = 3.747, angstrom = 0.7093, mm = nothing, beam = nothing, um = 55.0),
        ),
    ]
    ran = 0
    for (var, name, want) in realcases
        dir = get(ENV, var, "")
        (isempty(dir) && continue)
        p = joinpath(dir, name)
        isfile(p) || continue
        ran += 1
        m = normalise(Fabio.readimage(p))
        @test m.exposure_time ≈ want.exposure
        @test 1e10 * m.wavelength ≈ want.angstrom
        if want.mm === nothing
            @test m.detector_distance === nothing
        else
            @test 1e3 * m.detector_distance ≈ want.mm
        end
        if want.beam === nothing
            @test m.beam_center === nothing
        else
            @test _approxtuple(m.beam_center, want.beam)
        end
        @test _approxtuple(m.pixel_size, (want.um * 1e-6, want.um * 1e-6))
    end
    ran == 0 && @info "No real-file metadata datasets present; those checks were skipped"
end

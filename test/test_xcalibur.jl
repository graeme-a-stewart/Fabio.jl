using Fabio: XCALIBUR_PREFIX_BYTES, XCALIBUR_POLYGON_MAXPOINTS, XcaliburMask, XcaliburRecords

# --------------------------------------------------------------------------------------
# A CrysalisPro .ccd writer: the fixed prefix, then counted lists of records. Layout taken
# from FabIO's struct definitions, which are complete even though its reader is not.
# --------------------------------------------------------------------------------------

u16(v) = collect(reinterpret(UInt8, [htol(UInt16(v))]))
u32(v) = collect(reinterpret(UInt8, [htol(UInt32(v))]))
f64(v) = collect(reinterpret(UInt8, [htol(Float64(v))]))

"""A row or column record: start and end points, then replacements and flags."""
function xcal_span(x0, x1, y0, y1; size = 18)
    b = vcat(u16(x0), u16(y0), u16(x1), u16(y1))
    append!(b, zeros(UInt8, size - length(b)))
    return b
end

"""A point record: the point, two replacements, and a treatment code."""
xcal_point(x, y) = vcat(u16(x), u16(y), zeros(UInt8, 8), u16(0))

"""A polygon record: type, point count, then six x and six y coordinates."""
function xcal_polygon(xs, ys)
    b = vcat(u16(0), u16(length(xs)))
    for k = 1:XCALIBUR_POLYGON_MAXPOINTS
        append!(b, u16(k <= length(xs) ? xs[k] : 0))
    end
    for k = 1:XCALIBUR_POLYGON_MAXPOINTS
        append!(b, u16(k <= length(ys) ? ys[k] : 0))
    end
    return b
end

function write_ccd(path; points = [], rows = [], columns = [], polygons = [],
                   producer = "Fabio.jl", chiptype = "TestChip", scintillator = 3)
    prefix = zeros(UInt8, XCALIBUR_PREFIX_BYTES)
    prefix[1:4] = u32(1)                                     # dwversion
    prefix[5:12] = f64(0.125)                                # dark current
    prefix[13:20] = f64(2.5)                                 # read noise
    puttext(off, s) = (b = Vector{UInt8}(codeunits(s));
                       prefix[(off+1):(off+length(b))] = b)
    puttext(276, producer)
    puttext(532, chiptype)
    prefix[1813:1814] = u16(1)                               # iisfip60origin
    prefix[1815:1816] = u16(7)                               # ifip60xorigin
    prefix[1817:1818] = u16(9)                               # ifip60yorigin

    body = UInt8[]
    append!(body, u16(length(polygons)))
    for p in polygons
        append!(body, xcal_polygon(p[1], p[2]))
    end
    append!(body, u16(length(points)))
    for p in points
        append!(body, xcal_point(p[1], p[2]))
    end
    # Columns at native, 1x1, 2x2 and 4x4 binning; only the first is populated here.
    append!(body, u16(length(columns)))
    for c in columns
        append!(body, xcal_span(c...; size = 22))
    end
    for _ = 1:3
        append!(body, u16(0))
    end
    append!(body, u16(length(rows)))
    for r in rows
        append!(body, xcal_span(r...; size = 18))
    end
    append!(body, u16(scintillator))
    append!(body, f64(1.5))                                  # dgain_mo
    append!(body, f64(2.5))                                  # dgain_cu
    for _ = 1:3                                              # rows at 1x1, 2x2, 4x4
        append!(body, u16(0))
    end
    write(path, vcat(prefix, body))
    return path
end

@testset "Xcalibur (.ccd)" begin
    @testset "the fixed prefix" begin
        p = joinpath(TMP, "prefix.ccd")
        write_ccd(p; points = [(1, 1)], producer = "Rigaku", chiptype = "Titan")
        h = Fabio.readheader(p; format = Xcalibur())
        @test h["dwversion"] == 1
        @test h["ddarkcurrentinADUpersec"] ≈ 0.125
        @test h["dreadnoiseinADU"] ≈ 2.5
        @test h["cccdproducer"] == "Rigaku"
        @test h["cccdchiptype"] == "Titan"
        @test h["ifip60xorigin"] == 7
        @test h["ifip60yorigin"] == 9
        @test h["iscintillatorid"] == 3
        @test h["dgain_mo"] ≈ 1.5
        @test h["dgain_cu"] ≈ 2.5
    end

    @testset "records become a mask" begin
        p = joinpath(TMP, "mask.ccd")
        write_ccd(p;
                  points = [(0, 0), (5, 3)],
                  rows = [(2, 4, 1, 1)],          # x 2..4 on row y=1
                  columns = [(7, 7, 0, 2)])       # column x=7, y 0..2
        frame = Fabio.readimage(p; format = Xcalibur((10, 6)))
        @test eltype(frame) === UInt8
        @test size(frame) == (10, 6)
        d = collect(frame)
        # Coordinates are 0-based in the file and 1-based here.
        @test d[1, 1] == 1
        @test d[6, 4] == 1
        @test all(d[3:5, 2] .== 1)
        @test all(d[8, 1:3] .== 1)
        # Everything else stays clear.
        @test sum(d) == 2 + 3 + 3
        @test Fabio.readheader(p; format = Xcalibur())["MaskedRecords"] == 4
    end

    @testset "polygons are filled by their bounds" begin
        p = joinpath(TMP, "poly.ccd")
        write_ccd(p; polygons = [([1, 4, 4, 1], [2, 2, 5, 5])])
        d = collect(Fabio.readimage(p; format = Xcalibur((8, 8))))
        @test all(d[2:5, 3:6] .== 1)
        @test sum(d) == 4 * 4
    end

    @testset "the shape can be given or inferred" begin
        p = joinpath(TMP, "dims.ccd")
        write_ccd(p; points = [(3, 5)])
        given = Fabio.readimage(p; format = Xcalibur((64, 32)))
        @test size(given) == (64, 32)
        @test Fabio.readheader(p; format = Xcalibur((64, 32)))["DimsInferred"] === false

        # With no shape the mask is only large enough to hold the records, which is a lower
        # bound on the detector rather than its real extent.
        inferred = Fabio.readimage(p; format = Xcalibur())
        @test size(inferred) == (4, 6)
        @test inferred[4, 6] == 1
        @test Fabio.readheader(p; format = Xcalibur())["DimsInferred"] === true
    end

    @testset "counts are exposed for each record kind" begin
        p = joinpath(TMP, "counts.ccd")
        write_ccd(p; points = [(1, 1), (2, 2)], rows = [(0, 3, 4, 4)],
                  columns = [(1, 1, 0, 2), (2, 2, 0, 2)],
                  polygons = [([0, 1], [0, 1])])
        h = Fabio.readheader(p; format = Xcalibur())
        @test h["ibadpoints"] == 2
        @test h["ibadrows"] == 1
        @test h["ibadcolumns"] == 2
        @test h["ibadpolygons"] == 1
        @test h["ibadrows1x1"] == 0
        @test h["ibadcolumns4x4"] == 0
        @test h["MaskedRecords"] == 6
    end

    @testset "a mask outside the given shape is clipped, not an error" begin
        p = joinpath(TMP, "clip.ccd")
        write_ccd(p; points = [(1, 1), (500, 500)])
        d = collect(Fabio.readimage(p; format = Xcalibur((8, 8))))
        @test d[2, 2] == 1
        @test sum(d) == 1                  # the far point falls outside and is dropped
    end

    @testset "a file shorter than the prefix is refused" begin
        p = joinpath(TMP, "short.ccd")
        write(p, zeros(UInt8, 100))
        @test_throws Fabio.TruncatedFileError Fabio.openimage(p; format = Xcalibur())
    end

    @testset "a count that overruns the file is refused" begin
        p = joinpath(TMP, "overrun.ccd")
        write_ccd(p; points = [(1, 1)])
        raw = read(p)
        # Claim a thousand polygons where the file holds none.
        raw[(XCALIBUR_PREFIX_BYTES+1):(XCALIBUR_PREFIX_BYTES+2)] = u16(1000)
        q = joinpath(TMP, "overrun2.ccd")
        write(q, raw)
        @test_throws Fabio.TruncatedFileError Fabio.openimage(q; format = Xcalibur())
    end
end

using Fabio: SliceRange, SliceEllipsis, UnsupportedFormatError, scheme, filepath, datapath, dataslice, invalidreason,
    isabsolute, urlstring, slicestring, juliaindices, getdataset
using HDF5
using Logging

include("silx_url_cases.jl")
include("numpy_slice_cases.jl")

@testset "DataUrl parses as silx does" begin
    for (text, valid, absolute, sc, fp, dp, sl, reason) in SILX_PARSED_URLS
        u = @test_logs min_level = Logging.Error DataUrl(text)
        @test isvalid(u) == valid
        @test isabsolute(u) == absolute
        @test scheme(u) == sc
        @test filepath(u) == fp
        @test datapath(u) == dp
        @test dataslice(u) == sl
        @test invalidreason(u) == reason
        @test string(u) == text                  # parsed URLs keep their text
    end
end

@testset "DataUrl built from parts" begin
    for (fp, dp, sl, sc, path, valid, reason) in SILX_BUILT_URLS
        u = DataUrl(; file_path = fp, data_path = dp, data_slice = sl, scheme = sc)
        @test urlstring(u) == path
        @test isvalid(u) == valid
        @test invalidreason(u) == reason
        # silx's round-trip property: the text parses back to an equal URL.
        @test DataUrl(path) == u
        @test hash(DataUrl(path)) == hash(u)
    end
    # A bare integer or a single element is a one-element slice.
    @test dataslice(DataUrl(; file_path = "/a.h5", data_path = "/d", data_slice = 3)) == (3,)
    @test dataslice(DataUrl(; file_path = "/a.h5", data_path = "/d", data_slice = SliceRange())) ==
          (SliceRange(),)
    @test DataUrl(; file_path = nothing, data_path = "/p", scheme = "silx") |> invalidreason ==
          "Invalid file path"
end

@testset "DataUrl warnings, equality and display" begin
    @test_logs (:warn, r"More than one query key named 'path'") DataUrl("/a.h5?path=/x&path=/y")
    @test_logs (:warn, r"Query key \"foo\" unsupported") DataUrl("/a.h5?path=/x&foo=1")
    # Invalid URLs compare by their text, valid ones by their parts.
    @test DataUrl("silx:/a.h5?/b") == DataUrl("silx:///a.h5::/b")
    @test DataUrl("") == DataUrl("")
    @test DataUrl("foo:/a") != DataUrl("foo:/b")
    @test DataUrl("/a.h5") != DataUrl("silx:/a.h5")
    @test repr(DataUrl("/a.h5::/b")) == "DataUrl(\"/a.h5::/b\")"
    txt = sprint(show, MIME"text/plain"(), DataUrl("fabio:/a.edf?path=/x"))
    @test occursin("INVALID   : fabio URLs cannot have a data path", txt)
    @test occursin("scheme    : fabio", txt)
    @test slicestring((1, SliceRange(nothing, 2, 3), SliceEllipsis(), SliceRange(-1, nothing, nothing))) ==
          "1,:2:3,...,-1:"
end

@testset "juliaindices agrees with numpy" begin
    # The same 60 values in the same memory: numpy's (3, 4, 5) C-order array is Julia's
    # (5, 4, 3) column-major one.
    A = reshape(collect(0:59), 5, 4, 3)
    for (text, npshape, npvalues) in NUMPY_SLICES
        idx = juliaindices(dataslice(DataUrl("/a.h5?path=/d&slice=" * text)), size(A))
        R = A[idx...]
        @test reverse(size(R)) == npshape
        @test (R isa AbstractArray ? vec(R) : [R]) == npvalues
    end
    @test_throws BoundsError juliaindices((3,), (5, 4, 3))
    @test_throws BoundsError juliaindices((-4,), (5, 4, 3))
    @test_throws ArgumentError juliaindices((0, 0, 0, 0), (5, 4, 3))
    @test_throws ArgumentError juliaindices((SliceEllipsis(), SliceEllipsis()), (5, 4, 3))
    @test_throws ArgumentError juliaindices((SliceRange(nothing, nothing, 0),), (5, 4, 3))
end

@testset "getdata: fabio scheme" begin
    frames = [reshape(Float32.(1:12) .+ 100k, 4, 3) for k = 0:2]
    path = joinpath(TMP, "url_series.edf")
    writeimage(path, frames)

    @test getdata("fabio:$path") == frames[1]             # the first frame by default
    @test getdata("fabio:$path?slice=2") == frames[3]     # 0-based
    @test getdata(DataUrl("fabio://" * path * "?slice=1")) == frames[2]
    @test getdata("fabio:$path?slice=2") isa Matrix{Float32}
    @test_throws ArgumentError getdata("fabio:$path?slice=3")
    @test_throws ArgumentError getdata("fabio:$path?slice=-1")
    @test_throws ArgumentError getdata("fabio:$path?slice=0,1")
    @test_throws ArgumentError getdata("fabio:$path?slice=0:2")
    @test_throws ArgumentError getdata("fabio:$path?path=/x")     # invalid URL
    @test_throws ArgumentError getdata("fabio:$(path).missing")

    single = joinpath(TMP, "url_single.edf")
    writeimage(single, frames[1])
    @test getdata("fabio:$single?slice=0") == frames[1]
    err = try
        getdata("fabio:$single?slice=1")
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("has 1 frame, numbered from 0", sprint(showerror, err))

    # No scheme: silx is tried first and cannot read an EDF, so fabio serves it.
    @test getdata("$path?slice=1") == frames[2]
    @test getdata(path) == frames[1]

    # readimage takes the same URL and keeps the header.
    f = readimage(DataUrl("fabio:$path?slice=2"))
    @test f == frames[3]
    @test f.fileindex == 3
    @test haskey(header(f), "Dim_1")

    @test_throws UnsupportedFormatError getdata("http://hsds-server.tld/home/file")
    @test_throws UnsupportedFormatError readimage(DataUrl("https://hsds-server.tld/home/file"))
end

@testset "getdata: silx scheme on HDF5" begin
    path = joinpath(TMP, "url_data.h5")
    stack = reshape(collect(Int32, 0:59), 5, 4, 3)       # h5py sees (3, 4, 5)
    h5open(path, "w") do h
        h["entry/data/data"] = stack
        h["entry/title"] = "a title"
        h["entry/count"] = 42
    end

    @test getdata("silx:$path?/entry/data/data") == stack
    @test getdata("$path::/entry/data/data") == stack
    @test getdata("silx:$path?path=/entry/data/data&slice=0") == stack[:, :, 1]
    @test getdata("silx:$path?path=/entry/data/data&slice=-1,1") == stack[:, 2, 3]
    @test getdata("silx:$path?path=/entry/data/data&slice=1,2,3") === Int32(stack[4, 3, 2])
    @test getdata("silx:$path?path=/entry/data/data&slice=::-1") == stack[:, :, end:-1:1]
    @test getdata("silx:$path?path=/entry/data/data&slice=...,1:4:2") == stack[2:2:4, :, :]
    @test getdata("silx:$path?path=/entry/data/data&slice=5:") == stack[:, :, 1:0]
    @test getdata("silx:$path?/entry/title") == "a title"
    @test getdata("silx:$path?/entry/count") == 42

    # h5py agrees on what a slice selects: numpy's element [2, 1, 3] is 2*20 + 1*5 + 3.
    @test getdata("$path?path=/entry/data/data&slice=2,1,3") == 48

    @test_throws ArgumentError getdata("silx:$path?/entry/nothing")
    @test_throws ArgumentError getdata("silx:$path?/entry")                  # a group
    @test_throws ArgumentError getdata("silx:$path?path=/entry/count&slice=0")
    @test_throws ArgumentError getdata("silx:$path")                         # no data path
    @test_throws ArgumentError getdata("silx:$path?slice=0")                 # invalid URL

    # A plain HDF5 file holding no image is still readable by data path.
    plain = joinpath(TMP, "url_plain.h5")
    h5open(h -> (h["x"] = [1.0, 2.0, 3.0]), plain, "w")
    @test getdata("silx:$plain?path=/x&slice=1:") == [2.0, 3.0]

    # The fabio scheme reads the same file through the image readers.
    @test getdata("fabio:$path?slice=2") == stack[:, :, 3]
    @test readimage(DataUrl("$path::/entry/data/data?slice=1")) == stack[:, :, 2]

    # A data path into an image file is the NeXus view, which is not there yet.
    edf = joinpath(TMP, "url_series.edf")
    err = try
        getdata("silx:$edf?/scan_0/instrument/detector_0/data")
    catch e
        e
    end
    @test err isa UnsupportedFormatError
    @test occursin("fabio:", sprint(showerror, err))
    # With no scheme, both failures are reported.
    err = try
        getdata("$edf?/scan_0/instrument/detector_0/data")
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("neither as silx nor as fabio", sprint(showerror, err))
end

@testset "supportedextensions" begin
    exts = Fabio.supportedextensions()
    @test issorted(exts) && allunique(exts)
    @test all(startswith("*."), exts)
    @test "*.edf" in exts && "*.cbf" in exts && "*.h5" in exts
    w = Fabio.supportedextensions(; writable = true)
    @test "*.edf" in w
    @test "*.sfrm" in w                                  # Bruker writes
    @test "*.dm3" ∉ w                                    # DM3 is read-only
    @test issubset(w, exts)
end

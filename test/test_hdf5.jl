# The HDF5 family, through the FabioHDF5Ext package extension.
#
# Every fixture here is written by this test with HDF5.jl rather than downloaded, so the suite
# stays self-contained. The reference values are computed from the same arithmetic that built
# the fixture, never typed in. Where a value could not be derived that way — the sparse
# densification, whose ordering is a choice — it comes from FabIO reading these very files.

using HDF5

"""
Deterministic, position-dependent test data, so a transposition cannot go unnoticed.

The multipliers are a mixed radix — unique for every (x, y, frame) at the sizes used here, so
any reordering changes the values — but small enough that a frame still fits in the 16-bit
types some of these fixtures are written in.
"""
_h5pattern(::Type{T}, nx, ny, k = 0) where {T} =
    T[T(x + 61 * y + 1009 * k) for x = 1:nx, y = 1:ny]

_h5stack(::Type{T}, nx, ny, nframes) where {T} =
    cat((_h5pattern(T, nx, ny, k) for k = 1:nframes)...; dims = 3)

"""Position-sensitive checksum: aggregates alone survive a transposition, this does not."""
function _h5checksum(A)
    s = 0.0
    @inbounds for (i, v) in enumerate(vec(A))
        s += Float64(v) * i
    end
    return s
end

# Overridable so the fixtures can be written somewhere stable and handed to FabIO, which is
# how the values in this file were cross-checked. See STATUS.md.
const H5DIR = get(ENV, "FABIO_JL_H5_FIXTURE_DIR", mktempdir())
isdir(H5DIR) || mkpath(H5DIR)

# ------------------------------------------------------------------ fixture construction

"""An Eiger file in the current layout: `data_000001`, `data_000002`, … under `/entry/data`."""
function _write_eiger(path, chunks::Vector{Int}, nx, ny)
    h5open(path, "w") do h
        g = create_group(create_group(h, "entry"), "data")
        k = 0
        for (i, n) in enumerate(chunks)
            g[string("data_", lpad(i, 6, '0'))] =
                cat((_h5pattern(UInt32, nx, ny, k += 1) for _ = 1:n)...; dims = 3)
        end
    end
    return path
end

"""The older Eiger layout, with the datasets directly under `/entry`."""
function _write_eiger_elder(path, nx, ny, nframes)
    h5open(path, "w") do h
        e = create_group(h, "entry")
        for k = 1:nframes
            e[string("data_", lpad(k, 2, '0'))] = _h5pattern(UInt32, nx, ny, k)
        end
    end
    return path
end

function _write_lima(path, nx, ny, nframes)
    h5open(path, "w") do h
        attrs(h)["creator"] = "LIMA-1.9.0"
        attrs(h)["default"] = "entry_0000"
        e = create_group(h, "entry_0000")
        attrs(e)["default"] = "measurement/data"
        m = create_group(e, "measurement")
        m["data"] = _h5stack(Int32, nx, ny, nframes)
    end
    return path
end

function _write_lambda(path, nx, ny, nframes)
    h5open(path, "w") do h
        d = create_group(create_group(create_group(h, "entry"), "instrument"), "detector")
        d["description"] = "Lambda"
        d["local_name"] = "lambda_detector_1"
        d["data"] = _h5stack(UInt16, nx, ny, nframes)
    end
    return path
end

"""A plain HDF5 container: one dataset, no NeXus decoration."""
function _write_flat(path, name, A)
    h5open(path, "w") do h
        h[name] = A
    end
    return path
end

"""A NeXus file that nominates its data through the `default`/`signal` attribute chain."""
function _write_nexus_default(path, nx, ny)
    h5open(path, "w") do h
        attrs(h)["default"] = "entry"
        e = create_group(h, "entry")
        attrs(e)["default"] = "measured"
        g = create_group(e, "measured")
        attrs(g)["signal"] = "counts"
        g["counts"] = _h5pattern(Float32, nx, ny)
        # A second image dataset elsewhere, so the `default` chain is doing real work rather
        # than being confirmed by there only being one candidate.
        create_group(h, "other")["decoy"] = _h5pattern(Float32, 4, 5)
    end
    return path
end

"""The sparse fixture, in the layout FabIO's `SparseImage` expects."""
function _write_sparse(path)
    # (fast, slow) here; FabIO sees the transpose of this, which is what the reference below
    # was produced from.
    mask = Float32[
        0.0 0.5 1.0 1.5 2.0
        0.5 1.0 1.5 2.0 2.5
        1.0 1.5 2.0 2.5 3.0
        1.5 2.0 2.5 NaN 3.5
        2.0 2.5 3.0 3.5 4.0
        2.5 3.0 3.5 4.0 4.5
        3.0 3.5 4.0 4.5 NaN
    ]
    h5open(path, "w") do h
        attrs(h)["default"] = "entry"
        attrs(h)["creator"] = "pyFAI test"
        e = create_group(h, "entry")
        attrs(e)["pyFAI_sparse_frames"] = "sparse_data"
        g = create_group(e, "sparse_data")
        attrs(g)["dataformat"] = "sparse Bragg"
        g["mask"] = mask
        g["radius"] = Float32[0, 1, 2, 3, 4]
        g["background_avg"] = Float32[10 20; 8 17; 6 14; 4 11; 2 8]   # (nradius, nframes)
        g["background_std"] = Float32[1 2; 1 2; 1 2; 1 2; 1 2]
        g["frame_ptr"] = UInt32[0, 3, 5]
        g["index"] = UInt32[0, 9, 34, 4, 20]
        g["intensity"] = Int32[100, 250, 700, 1234, 4321]
        g["dummy"] = Int32(-1)
        create_group(create_group(e, "sparsify"), "configuration")["data"] =
            "{\"sparsify\": {\"cutoff_pick\": 3.5}}"
    end
    return path
end

@testset "HDF5" begin
    @testset "the family is registered in the core" begin
        e = Fabio.findformat(:hdf5)
        @test e !== nothing
        @test e.format isa Fabio.NexusLike
        @test any(m -> m.pattern == Fabio.HDF5_MAGIC, e.magics)
        @test "h5" in e.extensions && "nxs" in e.extensions
    end

    @testset "Eiger" begin
        # Two datasets of two and three frames: five frames, numbered across the pair.
        p = _write_eiger(joinpath(H5DIR, "eiger.h5"), [2, 3], 9, 7)
        Fabio.openimage(p) do f
            @test f.format == Fabio.NexusLike{:eiger}()
            @test length(f) == 5
            @test pixeltype(f) == UInt32
            for k = 1:5
                fr = f[k]
                @test size(fr) == (9, 7)
                @test collect(fr) == _h5pattern(UInt32, 9, 7, k)
                @test _h5checksum(fr) == _h5checksum(_h5pattern(UInt32, 9, 7, k))
            end
            # Frames 1–2 come from the first dataset, 3–5 from the second.
            @test header(f[1])["HDF5Path"] == "/entry/data/data_000001"
            @test header(f[3])["HDF5Path"] == "/entry/data/data_000002"
        end

        # A single dataset directly at /entry/data, rather than a group of them.
        p2 = joinpath(H5DIR, "eiger_single.h5")
        h5open(p2, "w") do h
            create_group(h, "entry")["data"] = _h5stack(UInt32, 6, 4, 3)
        end
        Fabio.openimage(p2) do f
            @test f.format == Fabio.NexusLike{:eiger}()
            @test length(f) == 3
            @test collect(f[2]) == _h5pattern(UInt32, 6, 4, 2)
        end

        # The older layout, one 2-D dataset per frame under /entry.
        p3 = _write_eiger_elder(joinpath(H5DIR, "eiger_elder.h5"), 5, 3, 4)
        Fabio.openimage(p3) do f
            @test f.format == Fabio.NexusLike{:eiger}()
            @test length(f) == 4
            @test collect(f[4]) == _h5pattern(UInt32, 5, 3, 4)
        end
    end

    @testset "LImA" begin
        p = _write_lima(joinpath(H5DIR, "lima.h5"), 8, 6, 3)
        Fabio.openimage(p) do f
            @test f.format == Fabio.NexusLike{:lima}()
            @test length(f) == 3
            @test pixeltype(f) == Int32
            @test size(f[1]) == (8, 6)
            @test collect(f[3]) == _h5pattern(Int32, 8, 6, 3)
            # FabIO names the detector from the second-to-last component of the entry's
            # `default` attribute.
            @test header(f[1])["detector"] == "measurement"
        end
    end

    @testset "Lambda" begin
        p = _write_lambda(joinpath(H5DIR, "lambda.h5"), 7, 5, 2)
        Fabio.openimage(p) do f
            @test f.format == Fabio.NexusLike{:lambda}()
            @test length(f) == 2
            @test pixeltype(f) == UInt16
            @test collect(f[2]) == _h5pattern(UInt16, 7, 5, 2)
            @test header(f[1])["detector"] == "lambda_detector_1"
        end

        # A NeXus file whose detector is *not* a Lambda must not be claimed as one.
        p2 = joinpath(H5DIR, "notlambda.h5")
        h5open(p2, "w") do h
            d = create_group(create_group(create_group(h, "entry"), "instrument"), "detector")
            d["description"] = "Pilatus"
            d["data"] = _h5stack(UInt16, 4, 4, 1)
        end
        Fabio.openimage(p2) do f
            @test !(f.format isa Fabio.NexusLike{:lambda})
        end
    end

    @testset "flat containers and the :: separator" begin
        A = _h5pattern(Float32, 11, 9)
        p = _write_flat(joinpath(H5DIR, "flat.h5"), "data", A)

        # Named explicitly, FabIO style.
        Fabio.openimage(p * "::/data") do f
            @test f.format == Fabio.NexusLike{:hdf5}()
            @test length(f) == 1
            @test collect(f[1]) == A
            @test header(f[1])["HDF5Path"] == "/data"
            # The frame's source is the file itself, not the container reference.
            @test f.path == p
        end

        # A file with exactly one image dataset needs no separator. FabIO makes it mandatory.
        Fabio.openimage(p) do f
            @test length(f) == 1
            @test collect(f[1]) == A
        end

        # A 3-D dataset in a flat container is a stack of frames.
        S = _h5stack(Int16, 6, 5, 4)
        p3 = _write_flat(joinpath(H5DIR, "flat3d.h5"), "stack", S)
        Fabio.openimage(p3 * "::/stack") do f
            @test length(f) == 4
            @test collect(f[3]) == _h5pattern(Int16, 6, 5, 3)
        end

        # Ambiguity is an error that names the candidates.
        p4 = joinpath(H5DIR, "ambiguous.h5")
        h5open(p4, "w") do h
            h["first"] = _h5pattern(Float32, 4, 4)
            h["second"] = _h5pattern(Float32, 5, 5)
        end
        err = try
            Fabio.openimage(p4)
            nothing
        catch e
            e
        end
        @test err isa Fabio.CorruptFileError
        @test occursin("/first", sprint(showerror, err))
        @test occursin("/second", sprint(showerror, err))
        # Naming one resolves it.
        Fabio.openimage(p4 * "::/second") do f
            @test size(f[1]) == (5, 5)
        end

        # A path that is not there says so.
        @test_throws Fabio.CorruptFileError Fabio.openimage(p * "::/nope")

        # The NeXus default/signal chain is preferred over guessing.
        p5 = _write_nexus_default(joinpath(H5DIR, "nexus_default.h5"), 10, 8)
        Fabio.openimage(p5) do f
            @test header(f[1])["HDF5Path"] == "/entry/measured/counts"
            @test size(f[1]) == (10, 8)
        end
    end

    @testset "sparse (sparsify-Bragg)" begin
        p = _write_sparse(joinpath(H5DIR, "sparse.h5"))
        # Produced by FabIO reading this same file, transposed into (fast, slow) order.
        # FabIO's Cython densify writes the peak list after the dummy fill, so the peak at
        # flat index 34 — a masked pixel — survives in frame 1 and is not replaced by -1.
        ref1 = permutedims(Int32[
            100 9 8 7 6 5 4
            9 8 250 6 5 4 3
            8 7 6 5 4 3 2
            7 6 5 -1 3 2 2
            6 5 4 3 2 2 700
        ])
        ref2 = permutedims(Int32[
            20 19 17 16 1234 13 11
            19 17 16 14 13 11 10
            17 16 14 13 11 10 4321
            16 14 13 -1 10 8 8
            14 13 11 10 8 8 -1
        ])
        Fabio.openimage(p) do f
            @test f.format == Fabio.NexusLike{:sparse}()
            @test length(f) == 2
            @test pixeltype(f) == Int32
            @test size(f[1]) == (7, 5)
            @test collect(f[1]) == ref1
            @test collect(f[2]) == ref2
        end
    end

    @testset "the public API works on HDF5 like any other format" begin
        p = _write_eiger(joinpath(H5DIR, "api.h5"), [3], 8, 6)
        @test Fabio.framesize(p) == (8, 6)
        @test Fabio.pixeltype(p) == UInt32
        @test collect(Fabio.readimage(p)) == _h5pattern(UInt32, 8, 6, 1)
        @test collect(Fabio.readimage(p; frame = 3)) == _h5pattern(UInt32, 8, 6, 3)
        @test length(Fabio.readheaders(p)) == 3
        @test Fabio.readheader(p)["HDF5Path"] == "/entry/data/data_000001"
        # A frame read after the file is closed still owns its data.
        fr = Fabio.readimage(p; frame = 2)
        @test parent(fr) isa Array
        @test collect(fr) == _h5pattern(UInt32, 8, 6, 2)
        # The stack, and reading into a preallocated buffer.
        Fabio.openimage(p) do f
            @test size(Fabio.framestack(f)) == (8, 6, 3)
            dest = Array{UInt32}(undef, 8, 6)
            @test Fabio.readframe!(dest, f, 2) === dest
            @test dest == _h5pattern(UInt32, 8, 6, 2)
            # Two frames from one file are independent arrays.
            @test collect(f[1]) != collect(f[2])
        end
        # The frame comes back with the file's own element type, concretely.
        #
        # Not `@inferred`, though: a tier-2 `readframe` reaches its descriptor through
        # `ImageFile.frames::Vector{FrameSpec}`, whose parameter is abstract, so the element
        # type is recovered at run time rather than inferred. That is a property of the frame
        # table shared with every other format here, not of HDF5 — and the dispatch it costs
        # is once per frame, against an HDF5 read of the whole frame.
        Fabio.openimage(p) do f
            @test typeof(Fabio.readframe(f, 1)) === ImageFrame{UInt32,2,Matrix{UInt32}}
        end
    end

    @testset "an in-memory buffer cannot be opened as HDF5" begin
        p = _write_flat(joinpath(H5DIR, "buf.h5"), "data", _h5pattern(Float32, 4, 4))
        raw = read(p)
        # Detection recognises the magic; what fails is that the HDF5 library has no path to
        # open. The error should say that, not claim the format was unrecognised.
        err = try
            Fabio.openimage(raw)
            nothing
        catch e
            e
        end
        @test err isa Fabio.UnsupportedFormatError
        @test occursin("HDF5", sprint(showerror, err))
    end
end

using Fabio: DM3_INLINE_LIMIT

# --------------------------------------------------------------------------------------
# A small Digital Micrograph writer, enough to build tag trees by hand. The tag structure
# is always big-endian; only stored values follow the file's declared order.
# --------------------------------------------------------------------------------------

be32(v) = collect(reinterpret(UInt8, [hton(UInt32(v))]))
bei32(v) = collect(reinterpret(UInt8, [hton(Int32(v))]))
be16(v) = collect(reinterpret(UInt8, [hton(UInt16(v))]))

"""A data tag holding one scalar."""
dm3_scalar(label, code, bytes) =
    vcat(UInt8[21], be16(length(label)), Vector{UInt8}(codeunits(label)),
         Vector{UInt8}(codeunits("%%%%")), bei32(1), bei32(code), bytes)

"""A data tag holding a simple array."""
dm3_array(label, code, count, payload) =
    vcat(UInt8[21], be16(length(label)), Vector{UInt8}(codeunits(label)),
         Vector{UInt8}(codeunits("%%%%")), bei32(3), bei32(20), bei32(code), bei32(count),
         payload)

"""A tag group entry wrapping `entries`."""
dm3_group(label, entries) =
    vcat(UInt8[20], be16(length(label)), Vector{UInt8}(codeunits(label)),
         UInt8[0, 0], be32(length(entries)), reduce(vcat, entries; init = UInt8[]))

"""Assemble a whole file from a list of root-level entries."""
function dm3_file(path, entries; little = true)
    body = vcat(UInt8[0, 0], be32(length(entries)), reduce(vcat, entries; init = UInt8[]))
    total = 12 + length(body)
    write(path, vcat(be32(3), be32(total), be32(little ? 1 : 0), body))
    return path
end

le16(v) = collect(reinterpret(UInt8, [htol(UInt16(v))]))
le32(v) = collect(reinterpret(UInt8, [htol(Int32(v))]))

@testset "DM3" begin
    @testset "a nested tree, with the image inside it" begin
        A = UInt16[10i + j for i = 1:8, j = 1:5]
        payload = reduce(vcat, (le16(v) for v in vec(A)); init = UInt8[])
        p = joinpath(TMP, "basic.dm3")
        dm3_file(p, [
            dm3_group("ImageList", [
                dm3_group("0", [
                    dm3_group("ImageData", [
                        dm3_array("Data", 4, length(A), payload),
                        dm3_group("Dimensions", [
                            dm3_scalar("0", 3, le32(8)),
                            dm3_scalar("1", 3, le32(5)),
                        ]),
                    ]),
                ]),
            ]),
        ])
        frame = Fabio.readimage(p)
        @test Fabio.openimage(f -> Fabio.imageformat(f), p) isa DM3
        @test eltype(frame) === UInt16
        @test size(frame) == (8, 5)
        @test collect(frame) == A
        h = header(frame)
        @test h["Version"] == 3
        @test h["ByteOrder"] == "LowByteFirst"
        # Keys are full paths, so a nested tag keeps its position in the tree.
        @test h["ImagePath"] == "ImageList.0.ImageData.Data"
        @test h["ImageList.0.ImageData.Dimensions.0"] == 8
        @test h["ImageList.0.ImageData.Dimensions.1"] == 5
    end

    @testset "a thumbnail does not win over the image" begin
        # A real .dm3 holds two arrays called Data. FabIO keeps only the leaf label, so the
        # later one overwrites the earlier and which is returned depends on file order. Here
        # the larger array is the image whichever way round they appear.
        img = UInt16[10i + j for i = 1:8, j = 1:5]
        thumb = UInt16[1 2; 3 4]
        imgpay = reduce(vcat, (le16(v) for v in vec(img)); init = UInt8[])
        thumbpay = reduce(vcat, (le16(v) for v in vec(thumb)); init = UInt8[])

        for (order, name) in ((:thumbfirst, "tf.dm3"), (:imagefirst, "if.dm3"))
            entries = [
                dm3_group("ImageList", [
                    dm3_group("0", [dm3_group("ImageData", [
                        dm3_array("Data", 4, length(thumb), thumbpay),
                        dm3_group("Dimensions", [dm3_scalar("0", 3, le32(2)),
                                                 dm3_scalar("1", 3, le32(2))])])]),
                    dm3_group("1", [dm3_group("ImageData", [
                        dm3_array("Data", 4, length(img), imgpay),
                        dm3_group("Dimensions", [dm3_scalar("0", 3, le32(8)),
                                                 dm3_scalar("1", 3, le32(5))])])]),
                ]),
            ]
            order === :imagefirst && (entries[1] = dm3_group("ImageList", reverse(
                [dm3_group("0", [dm3_group("ImageData", [
                     dm3_array("Data", 4, length(thumb), thumbpay),
                     dm3_group("Dimensions", [dm3_scalar("0", 3, le32(2)),
                                              dm3_scalar("1", 3, le32(2))])])]),
                 dm3_group("1", [dm3_group("ImageData", [
                     dm3_array("Data", 4, length(img), imgpay),
                     dm3_group("Dimensions", [dm3_scalar("0", 3, le32(8)),
                                              dm3_scalar("1", 3, le32(5))])])])])))
            p = joinpath(TMP, name)
            dm3_file(p, entries)
            frame = Fabio.readimage(p)
            @test size(frame) == (8, 5)
            @test collect(frame) == img
            # Both arrays are still in the header, under distinct paths.
            @test count(k -> endswith(k, ".Data"), collect(keys(header(frame)))) == 2
        end
    end

    @testset "big-endian files" begin
        A = UInt16[0x0102 0x0304; 0x0506 0x0708]
        payload = reduce(vcat, (collect(reinterpret(UInt8, [hton(v)])) for v in vec(A));
                         init = UInt8[])
        p = joinpath(TMP, "be.dm3")
        dm3_file(p, [dm3_group("ImageData", [
            dm3_array("Data", 4, length(A), payload),
            dm3_group("Dimensions", [dm3_scalar("0", 3, bei32(2)),
                                     dm3_scalar("1", 3, bei32(2))]),
        ])]; little = false)
        frame = Fabio.readimage(p)
        @test header(frame)["ByteOrder"] == "HighByteFirst"
        @test collect(frame) == A
    end

    @testset "scalars of each width" begin
        A = UInt16[1 2; 3 4]
        payload = reduce(vcat, (le16(v) for v in vec(A)); init = UInt8[])
        p = joinpath(TMP, "scalars.dm3")
        dm3_file(p, [
            dm3_scalar("AnInt16", 2, le16(-3 % UInt16)),
            dm3_scalar("AnInt32", 3, le32(70000)),
            dm3_scalar("AFloat32", 6, collect(reinterpret(UInt8, [htol(Float32(1.5))]))),
            dm3_scalar("AFloat64", 7, collect(reinterpret(UInt8, [htol(Float64(2.25))]))),
            dm3_scalar("AnInt8", 8, UInt8[0xff]),
            dm3_group("ImageData", [
                dm3_array("Data", 4, length(A), payload),
                dm3_group("Dimensions", [dm3_scalar("0", 3, le32(2)),
                                         dm3_scalar("1", 3, le32(2))]),
            ]),
        ])
        h = Fabio.readheader(p)
        @test h["AnInt16"] == -3
        @test h["AnInt32"] == 70000
        @test h["AFloat32"] ≈ 1.5
        @test h["AFloat64"] ≈ 2.25
        @test h["AnInt8"] == -1
    end

    @testset "text is stored as a UInt16 array and comes back as a string" begin
        A = UInt16[1 2; 3 4]
        payload = reduce(vcat, (le16(v) for v in vec(A)); init = UInt8[])
        text = "Gatan"
        textpay = reduce(vcat, (le16(UInt16(c)) for c in text); init = UInt8[])
        p = joinpath(TMP, "text.dm3")
        dm3_file(p, [
            dm3_array("DeviceName", 4, length(text), textpay),
            dm3_group("ImageData", [
                dm3_array("Data", 4, length(A), payload),
                dm3_group("Dimensions", [dm3_scalar("0", 3, le32(2)),
                                         dm3_scalar("1", 3, le32(2))]),
            ]),
        ])
        h = Fabio.readheader(p)
        @test h["DeviceName"] == "Gatan"
    end

    @testset "the version is checked" begin
        p = joinpath(TMP, "v4.dm3")
        write(p, vcat(be32(4), be32(64), be32(1), zeros(UInt8, 52)))
        @test_throws Fabio.UnsupportedFormatError Fabio.openimage(p; format = DM3())
    end

    @testset "a file with no array is refused" begin
        p = joinpath(TMP, "noarray.dm3")
        dm3_file(p, [dm3_scalar("Lonely", 3, le32(1))])
        @test_throws Fabio.CorruptFileError Fabio.openimage(p)
    end

    @testset "a missing %%%% marker is reported" begin
        A = UInt16[1 2; 3 4]
        payload = reduce(vcat, (le16(v) for v in vec(A)); init = UInt8[])
        p = joinpath(TMP, "marker.dm3")
        dm3_file(p, [dm3_array("Data", 4, length(A), payload)])
        raw = read(p)
        i = findfirst(k -> raw[k:k+3] == Vector{UInt8}(codeunits("%%%%")), 1:(length(raw)-4))
        raw[i] = UInt8('X')
        q = joinpath(TMP, "marker2.dm3")
        write(q, raw)
        @test_throws Fabio.CorruptFileError Fabio.openimage(q)
    end

    @testset "a large array stays out of the header" begin
        n = DM3_INLINE_LIMIT + 16
        A = ones(UInt16, n, 1)
        payload = reduce(vcat, (le16(v) for v in vec(A)); init = UInt8[])
        p = joinpath(TMP, "big.dm3")
        dm3_file(p, [dm3_group("ImageData", [
            dm3_array("Data", 4, n, payload),
            dm3_group("Dimensions", [dm3_scalar("0", 3, le32(n)),
                                     dm3_scalar("1", 3, le32(1))]),
        ])])
        h = Fabio.readheader(p)
        # Described, not loaded.
        @test h["ImageData.Data"] isa AbstractString
        @test occursin(string(n), h["ImageData.Data"])
        @test collect(Fabio.readimage(p)) == A
    end
end

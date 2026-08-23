"""
    Fabio

Reading of 2D detector images and their metadata, after the Python
[FabIO](https://github.com/silx-kit/fabio) library: give it a filename and it works out the
format, handles any compression, and hands back the pixels as a Julia array of the type
actually stored in the file, alongside the header.

```julia
using Fabio, Statistics

frame = Fabio.readimage("image.edf")
mean(frame)                                    # an ImageFrame is an AbstractArray
getheader(header(frame), "ESRFCurrent", Float64)

Fabio.openimage("series.edf") do file          # multi-frame files are AbstractVectors
    for f in file
        println(f.fileindex, ": ", maximum(f))
    end
end
```

# Axis order

`size(frame) == (fast, slow)` — the fast-varying detector axis comes first, the reverse of
numpy's `.shape` as reported by FabIO. This is what lets stored bytes map onto Julia's
column-major memory with no permutation, which in turn makes memory-mapped, zero-copy frames
possible. [`rowmajor`](@ref) and [`imageview`](@ref) give free views in the other conventions.

# Naming

FabIO's `fabio.open` is [`openimage`](@ref) here, and `fabio.open(...).data` is
[`readimage`](@ref). Adding methods to `Base.open(::AbstractString)` would be type piracy, so
the path-based entry points get distinct names; everything that dispatches on this package's
own types (`close`, `length`, `getindex`, iteration) extends `Base` as usual.

# Extending

See [`scan`](@ref) for the tier-1 extension point (parse a header, return a
[`BinaryLayout`](@ref); the core does the rest), [`readframe`](@ref) for tier 2, and
[`register!`](@ref) for wiring a format in — including from another package.
"""
module Fabio

using OrderedCollections: OrderedDict
using CodecZlib: GzipDecompressor, GzipCompressor, ZlibDecompressor, ZlibCompressor
using TranscodingStreams: transcode
import Mmap
using Dates: DateTime, @dateformat_str
using Base64: base64encode, base64decode

export ImageFrame,
    ImageFile,
    Header,
    ImageFormat,
    getheader,
    header,
    data,
    rowmajor,
    imageview,
    pixeltype,
    openimage,
    ImageMetadata,
    normalise,
    open_series,
    readimage,
    writeimage,
    convertimage,
    readheader,
    readheaders

include("types.jl")
include("md5.jl")
include("header.jl")
include("frame.jl")
include("source.jl")
include("codecs.jl")
include("agi.jl")
include("byteoffset.jl")
include("pck.jl")
include("blob.jl")
include("registry.jl")
include("detect.jl")
include("file.jl")
include("api.jl")
include("write.jl")
include("series.jl")

include("formats/bruker.jl")
include("formats/cbf.jl")
include("formats/dm3.jl")
include("formats/dtrek.jl")
include("formats/edf.jl")
include("formats/ge.jl")
include("formats/esperanto.jl")
include("formats/fit2d.jl")
include("formats/fit2dmask.jl")
include("formats/kcd.jl")
include("formats/mar345.jl")
include("formats/mpa.jl")
include("formats/mrc.jl")
include("formats/nexus.jl")
include("formats/oxd.jl")
include("formats/pnm.jl")
include("formats/raxis.jl")
include("formats/spe.jl")
include("formats/npy.jl")
include("formats/tiff.jl")
include("formats/xcalibur.jl")

# After the formats: every `normalise` method dispatches on one of them.
include("metadata.jl")
include("cli.jl")

export Bruker, CBF, DM3, Dtrek, EDF, OXD, Xcalibur, Esperanto, Fit2D, Fit2DMask, KCD, MPA, GE, Mar345, MRC, NexusLike, NPY, PNM, Raxis, SPE, TIFFLike

"""
    registerdefaults!()

Register the formats built into this package. Called from `__init__`, and safe to call again.

Ordering here does not matter: [`register!`](@ref) sorts the registry by priority and then by
magic-pattern length, so the most specific signature always wins regardless of when it was
added. FabIO, by contrast, relies on the declaration order of its magic table.
"""
function registerdefaults!()
    register!(
        Esperanto();
        name = :esperanto,
        description = "CrysAlis Pro Esperanto",
        extensions = ["esperanto", "esper"],
        magic = [Magic("ESPERANTO FORMAT")],
    )
    register!(
        CBF();
        name = :cbf,
        description = "CIF Binary Format (Pilatus and others)",
        extensions = ["cbf"],
        magic = [Magic("###CBF: VERSION"), Magic("###CBF:")],
    )
    register!(
        Dtrek();
        name = :dtrek,
        description = "d*TREK / ADSC Quantum",
        extensions = ["img"],
        # Longer than EDF's bare "{", so the registry orders it first without special cases.
        magic = [Magic("{\nHEA"), Magic("{\r\nHEA")],
    )
    register!(
        Bruker{86}();
        name = :bruker,
        description = "Bruker area detector (FORMAT:86)",
        extensions = ["sfrm"],
        magic = [Magic("FORMAT :")],
    )
    register!(
        Bruker{100}();
        name = :bruker100,
        description = "Bruker area detector (FORMAT:100)",
        extensions = ["sfrm"],
    )
    register!(
        Mar345();
        name = :mar345,
        description = "MAR Research image plate (mar345/mar300)",
        # The 4-byte 1234 marker, little- and big-endian. FabIO also lists two-byte
        # variants, but those are short enough to collide with unrelated formats.
        magic = [Magic(UInt8[0xD2, 0x04, 0x00, 0x00]), Magic(UInt8[0x00, 0x00, 0x04, 0xD2])],
        extensions = ["mar345", "mar3450", "mar3000", "mar2400", "mar2300",
                      "mar2000", "mar1800", "mar1600", "mar1200"],
    )
    # The TIFF family. Pilatus is caught by its own longer signature — its first IFD sits at
    # byte 0x82 — while MarCCD has no distinct magic and is resolved by `refine`.
    register!(
        TIFFLike{:pilatus}();
        name = :pilatus,
        description = "Dectris Pilatus (TIFF with a text header)",
        extensions = ["tif", "tiff"],
        magic = [Magic(UInt8[0x49, 0x49, 0x2A, 0x00, 0x82, 0x00])],
    )
    register!(
        TIFFLike{:marccd}();
        name = :marccd,
        description = "MarCCD / Mar165 (TIFF with a binary header)",
        extensions = ["mccd"],
    )
    register!(
        TIFFLike{:plain}();
        name = :tiff,
        description = "Tagged Image File Format (baseline, uncompressed)",
        extensions = ["tif", "tiff"],
        magic = [Magic(TIFF_LE), Magic(TIFF_BE)],
    )
    register!(
        Fit2D{:little}();
        name = :fit2d,
        description = "Fit2D binary (record-structured)",
        extensions = ["f2d"],
        magic = [Magic("\\\$FFF_START")],
    )
    register!(
        Fit2DMask();
        name = :fit2dmask,
        description = "Fit2D mask (one bit per pixel)",
        extensions = ["msk"],
        magic = [Magic(UInt8['M', 0, 0, 0, 'A', 0, 0, 0, 'S', 0, 0, 0, 'K', 0, 0, 0])],
    )
    register!(
        Raxis();
        name = :raxis,
        description = "Rigaku R-AXIS imaging plate",
        extensions = ["img", "osc"],
        magic = [Magic("R-AXIS"), Magic("RAXIS")],
    )
    register!(
        SPE();
        name = :spe,
        description = "Princeton Instruments WinSpec (multi-frame)",
        extensions = ["spe"],
    )
    register!(
        DM3();
        name = :dm3,
        description = "Gatan Digital Micrograph",
        extensions = ["dm3"],
        magic = [Magic(UInt8[0x00, 0x00, 0x00, 0x03])],
    )
    register!(
        KCD();
        name = :kcd,
        description = "Nonius KappaCCD",
        extensions = ["kcd"],
        magic = [Magic("No")],
        priority = -1,          # a two-byte signature, so let longer ones win
    )
    register!(
        MPA();
        name = :mpa,
        description = "Multi-wire detector (FastComTec)",
        extensions = ["mpa"],
        magic = [Magic("[ADC1]")],
    )
    register!(
        MRC();
        name = :mrc,
        description = "MRC / CCP4 map (multi-frame)",
        extensions = ["mrc", "map", "fei"],
        magic = [Magic("MAP ", 208), Magic("MAP\0", 208)],
    )
    register!(
        OXD();
        name = :oxd,
        description = "Oxford Diffraction / KM4 CCD",
        extensions = ["img"],
        magic = [Magic("OD")],
        priority = -1,           # a two-byte signature, so let longer ones win
    )
    # No magic number and no extension FabIO recognises, so it is reached by an explicit
    # `format = Xcalibur(...)` rather than by detection.
    register!(
        Xcalibur();
        name = :xcalibur,
        description = "CrysalisPro chip characteristics (bad-pixel mask)",
        extensions = ["ccd"],
    )
    register!(
        PNM();
        name = :pnm,
        description = "Netpbm greyscale and bitmap (P1, P2, P4, P5)",
        extensions = ["pnm", "pgm", "pbm"],
        magic = [Magic("P1"), Magic("P2"), Magic("P4"), Magic("P5")],
    )
    register!(
        GE();
        name = :ge,
        description = "General Electric detector (multi-frame)",
        # FabIO matches an extension of "ge" followed by any digits; the registry does exact
        # matches, so the ones that occur in practice are listed.
        extensions = ["ge", "ge1", "ge2", "ge3", "ge4", "ge5"],
        # A firmware update at APS began writing the header as zeros, so a run of ten zero
        # bytes is the signature of a blanked GE file. It is given the lowest priority in the
        # table, below even EDF's bare brace, since it is the least selective signature here.
        magic = [Magic("ADEPT"), Magic(zeros(UInt8, 10))],
        priority = -2,
    )
    # One entry for the whole HDF5 family. Which member a file actually is cannot be told
    # from its first bytes — every one of them starts with the same eight — so `refine` opens
    # the file and looks at its structure, and that method lives in the HDF5 extension. With
    # the extension unloaded the family still resolves here, and `scan` then explains what to
    # load. FabIO instead encodes the family as the magic-table string
    # "eiger/lima/sparse/hdf5/lambda" and unpicks it with a branch inside its detection loop.
    register!(
        NexusLike{:unknown}();
        name = :hdf5,
        description = "HDF5 / NeXus (Eiger, LImA, Lambda, sparsify-Bragg)",
        extensions = ["h5", "hdf5", "nxs"],
        magic = [Magic(HDF5_MAGIC)],
    )
    register!(
        NPY();
        name = :npy,
        description = "NumPy array container",
        extensions = ["npy"],
        magic = [Magic(NPY_MAGIC)],
    )
    register!(
        EDF();
        name = :edf,
        description = "ESRF Data Format",
        extensions = ["edf", "cor"],
        magic = [
            Magic("{\r\nEDF"),
            Magic("\n{\r\nEDF"),
            Magic("{\r\n"),
            Magic("{\n"),
            Magic("\n{\n"),
            Magic("{"),
        ],
        priority = -1,   # EDF's bare "{" is the least specific signature in the table
    )
    return REGISTRY
end

function __init__()
    registerdefaults!()
    return nothing
end

end # module

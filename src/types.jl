"""
    ImageFormat

Abstract supertype of all file formats. Concrete formats are singleton (or lightly
parameterised) marker types used only for dispatch — they never hold state. Per-file state
lives in [`ImageFile`](@ref)'s `state` field.
"""
abstract type ImageFormat end

"""Byte order of a stored binary blob."""
abstract type ByteOrder end
struct LittleEndian <: ByteOrder end
struct BigEndian <: ByteOrder end

const NativeByteOrder = ifelse(Base.ENDIAN_BOM == 0x04030201, LittleEndian, BigEndian)

isnative(::T) where {T<:ByteOrder} = T === NativeByteOrder

"""
    Orientation

How a decoded blob must be transformed to reach the canonical orientation of the format.
Applied once, in the core, so formats never permute arrays themselves.
"""
abstract type Orientation end
struct Identity <: Orientation end
struct FlipFast <: Orientation end   # reverse the first (fast) Julia axis
struct FlipSlow <: Orientation end   # reverse the second (slow) Julia axis

# ---------------------------------------------------------------------------- errors

"""
    FabioError <: Exception

Supertype of every error this package raises deliberately.

Catching this catches a file being unreadable — unrecognised, truncated, inconsistent, or in a
format whose reader is not loaded — while letting a genuine bug through rather than swallowing
it.
"""
abstract type FabioError <: Exception end

"""Raised when no registered format matches a file."""
struct UnknownFormatError <: FabioError
    path::String
    msg::String
end
Base.showerror(io::IO, e::UnknownFormatError) =
    print(io, "UnknownFormatError: ", e.path, ": ", e.msg)

"""Raised when a format is recognised but its reader is unavailable or unimplemented."""
struct UnsupportedFormatError <: FabioError
    msg::String
end
Base.showerror(io::IO, e::UnsupportedFormatError) =
    print(io, "UnsupportedFormatError: ", e.msg)

"""Raised when a file's header is internally inconsistent or its data cannot be decoded."""
struct CorruptFileError <: FabioError
    msg::String
end
Base.showerror(io::IO, e::CorruptFileError) = print(io, "CorruptFileError: ", e.msg)

"""Raised when a file ends before the header says it should. See `openimage(...; strict=false)`."""
struct TruncatedFileError <: FabioError
    msg::String
end
Base.showerror(io::IO, e::TruncatedFileError) = print(io, "TruncatedFileError: ", e.msg)

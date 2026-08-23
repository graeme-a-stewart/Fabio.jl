"""
MD5, for the `Content-MD5` field of a CBF binary section.

Julia's standard library ships SHA but not MD5, and MD5 is used here purely as a checksum over
a byte range that the file itself declares the length of — CBF was specified in 1998 and this
is the digest it names. Rather than take a dependency for one fixed, fully specified algorithm
in a package whose design goal is to install in seconds, RFC 1321 is implemented directly. The
RFC's own test vectors are in the test suite.
"""

"""Per-round left-rotation amounts, RFC 1321 section 3.4."""
const MD5_SHIFTS = UInt32[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

"""The sine-derived constants, `floor(abs(sin(i)) * 2^32)`."""
const MD5_SINES = UInt32[floor(UInt64, abs(sin(Float64(i))) * 4294967296.0) % UInt32 for i = 1:64]

"""
    md5(data) -> NTuple{16,UInt8}

The MD5 digest of `data`, as sixteen bytes.
"""
function md5(data::AbstractVector{UInt8})
    a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

    n = length(data)
    # Append 0x80, then zeros until the length is 56 mod 64, then the bit count little-endian.
    padlen = mod(56 - (n + 1), 64)
    total = n + 1 + padlen + 8
    msg = Vector{UInt8}(undef, total)
    copyto!(msg, 1, data, firstindex(data), n)
    msg[n+1] = 0x80
    for i = (n+2):(total-8)
        msg[i] = 0x00
    end
    bits = UInt64(n) * 8
    for i = 0:7
        msg[total-7+i] = UInt8((bits >> (8 * i)) & 0xff)
    end

    chunk = Vector{UInt32}(undef, 16)
    for base = 1:64:total
        @inbounds for j = 0:15
            o = base + 4 * j
            chunk[j+1] =
                UInt32(msg[o]) | (UInt32(msg[o+1]) << 8) |
                (UInt32(msg[o+2]) << 16) | (UInt32(msg[o+3]) << 24)
        end
        a, b, c, d = a0, b0, c0, d0
        @inbounds for i = 0:63
            local f::UInt32, g::Int
            if i < 16
                f = (b & c) | (~b & d)
                g = i
            elseif i < 32
                f = (d & b) | (~d & c)
                g = (5i + 1) % 16
            elseif i < 48
                f = xor(b, c, d)
                g = (3i + 5) % 16
            else
                f = xor(c, (b | ~d))
                g = (7i) % 16
            end
            f = f + a + MD5_SINES[i+1] + chunk[g+1]
            a = d
            d = c
            c = b
            b = b + bitrotate(f, MD5_SHIFTS[i+1])
        end
        a0 += a
        b0 += b
        c0 += c
        d0 += d
    end

    out = Vector{UInt8}(undef, 16)
    for (i, w) in enumerate((a0, b0, c0, d0))
        for j = 0:3
            out[4*(i-1)+j+1] = UInt8((w >> (8 * j)) & 0xff)
        end
    end
    return NTuple{16,UInt8}(out)
end

md5(s::AbstractString) = md5(Vector{UInt8}(codeunits(s)))

"""
    md5hex(data) -> String

The digest as 32 lowercase hexadecimal characters, the form RFC 1321's test vectors use.
"""
md5hex(data) = join(string(b; base = 16, pad = 2) for b in md5(data))

"""
    md5base64(data) -> String

The digest base64-encoded, which is the form CBF's `Content-MD5` field takes.
"""
md5base64(data) = base64encode(collect(md5(data)))

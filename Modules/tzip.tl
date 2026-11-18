# tzip -- read and write ZIP archives as an importable module.
#
#   import "Modules/tzip.tl"
#
#   let n = zip_open("bundle.zip")
#   if n < 0 { print("bad zip\n") return }
#   for i in 0..n {
#     print(zip_name(i) + "\n")
#     zip_extract(i, "out/" + zip_name(i))
#   }
#
# Writing is streaming: zip_create opens the file, zip_add/zip_add_file append
# local headers and data immediately, and zip_finish writes the central
# directory and end record. Each entry is DEFLATE-compressed when that makes it
# smaller and stored otherwise, so the result stays readable by unzip,
# Python's zipfile and Info-ZIP while avoiding needless expansion.
#
# Reading accepts stored and deflated entries with fixed or dynamic Huffman
# codes; zip_data/zip_extract return the uncompressed bytes. ZIP64, encryption
# and split archives are rejected, as are compression methods other than 0 and
# 8.
#
# Limits: 256 entries, 4 GiB per entry, and 16-bit name/extra/comment fields
# (the format's classic limit). The whole archive is read into memory because
# read_file has no streaming mode. DEFLATE uses a fixed 16K-slot/4-way hash
# table for matches, so it favours bounded memory over `zip -9` ratios.

let ZIP_MAX_ENTRIES = 256

let ZIP_OK = 0
let ZIP_E_FORMAT = 1
let ZIP_E_METHOD = 2
let ZIP_E_IO = 3
let ZIP_E_LIMIT = 4
let ZIP_E_ARG = 5

# Reading state.
let ZIP_SRC = ""
let ZIP_LEN = 0
let ZIP_COUNT = 0
let ZIP_NAMES = alloc(256, str)
let ZIP_SIZES = alloc(256)
let ZIP_COMP_SIZES = alloc(256)
let ZIP_CRCS = alloc(256)
let ZIP_METHODS = alloc(256)
let ZIP_DATA_OFFSETS = alloc(256)

# Writing state.
let ZIP_FD = -1
let ZIP_POS = 0
let ZIP_NAMES_OUT = alloc(256, str)
let ZIP_SIZES_OUT = alloc(256)
let ZIP_COMP_SIZES_OUT = alloc(256)
let ZIP_CRCS_OUT = alloc(256)
let ZIP_METHODS_OUT = alloc(256)
let ZIP_OFFSETS_OUT = alloc(256)

let ZIP_ERR = ZIP_OK
let ZIP_CRC_TABLE = alloc(256)
let ZIP_CRC_READY = 0

# DEFLATE tables, shared by the encoder and decoder. The base/extra entries
# follow RFC 1951 sections 3.2.5; the code-length order is section 3.2.7.
let ZIP_TABLES_READY = 0
let ZIP_LEN_BASE = alloc(29)
let ZIP_LEN_EXTRA = alloc(29)
let ZIP_DIST_BASE = alloc(30)
let ZIP_DIST_EXTRA = alloc(30)
let ZIP_CL_ORDER = alloc(19)

# Bit writer for compression. ZIP_BW holds ZIP_BW_LEN finished bytes; the low
# ZIP_BW_NBITS bits of ZIP_BW_BITS are the pending partial byte.
let ZIP_BW = ""
let ZIP_BW_LEN = 0
let ZIP_BW_CAP = 0
let ZIP_BW_BITS = 0
let ZIP_BW_NBITS = 0
let ZIP_BW_BAD = 0

# Bit reader for decompression. ZIP_IN_POS walks ZIP_IN[off..end); consumed
# bits live in ZIP_IN_BITS, low bit first.
let ZIP_IN = ""
let ZIP_IN_POS = 0
let ZIP_IN_END = 0
let ZIP_IN_BITS = 0
let ZIP_IN_NBITS = 0
let ZIP_IN_BAD = 0

# Canonical Huffman decoding tables for three alphabets: 0 literal/length,
# 1 distance, 2 code-length. Each alphabet gets 288 slots so one layout serves
# all three; only the first `n` entries of a given alphabet are meaningful.
let ZIP_H_LENS = alloc(864)
let ZIP_H_COUNTS = alloc(48)
let ZIP_H_FIRST = alloc(48)
let ZIP_H_OFF = alloc(48)
let ZIP_H_SYMS = alloc(864)
let ZIP_DYN_LENS = alloc(318)

# Greedy LZ77 hash table: four most-recent positions per 12-bit hash bucket.
let ZIP_HASH_SIZE = 4096
let ZIP_HASH_DEPTH = 4
let ZIP_HASH = alloc(16384)
let ZIP_MATCH_DIST = 0

# Inflate output is kept in globals so the literal/length loop can stay a
# separate function without passing an output buffer by reference.
let ZIP_OUT = ""
let ZIP_OUT_POS = 0
let ZIP_OUT_SIZE = 0

fn zip_error() -> int {
  return ZIP_ERR
}

fn zip_count() -> int {
  return ZIP_COUNT
}

# ---------------------------------------------------------------- little endian

fn zip_put16(buf: str, off: int, value: int) {
  st16(buf, off, value & 65535)
}

fn zip_put32(buf: str, off: int, value: int) {
  st32(buf, off, value & 0xFFFFFFFF)
}

fn zip_copy_name(dst: str, at: int, name: str, n: int) {
  for i in 0..n {
    dst[at + i] = name[i]
  }
}

# slice() stops its bound check at the first NUL, so it cannot copy a range out
# of a binary read_file buffer. A ZIP header is full of zero bytes; copy the
# requested bytes explicitly instead. The result is a newbuf, so callers must
# pass its length separately when it may contain NULs.
fn zip_copy_bytes(src: str, off: int, n: int) -> str {
  if n <= 0 {
    return ""
  }
  let out = newbuf(n)
  let i = 0
  while i < n {
    out[i] = src[off + i]
    i = i + 1
  }
  return out
}

# --------------------------------------------------------------------- CRC-32

fn zip_crc_init() {
  if ZIP_CRC_READY == 1 {
    return
  }
  let i = 0
  while i < 256 {
    let c = i
    let k = 0
    while k < 8 {
      if c & 1 {
        c = 0xEDB88320 ^ (c >> 1)
      } else {
        c = c >> 1
      }
      c = c & 0xFFFFFFFF
      k = k + 1
    }
    ZIP_CRC_TABLE[i] = c
    i = i + 1
  }
  ZIP_CRC_READY = 1
}

# The standard reflected CRC-32 (polynomial 0xEDB88320), as used by ZIP and
# gzip. `n` is explicit because the data may contain NUL bytes.
fn zip_crc32(data: str, n: int) -> int {
  zip_crc_init()
  let crc = 0xFFFFFFFF
  let i = 0
  while i < n {
    crc = (crc >> 8) ^ ZIP_CRC_TABLE[(crc ^ data[i]) & 255]
    crc = crc & 0xFFFFFFFF
    i = i + 1
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
}

# --------------------------------------------------------------- DEFLATE shared tables

fn zip_tables_init() {
  if ZIP_TABLES_READY == 1 {
    return
  }
  ZIP_LEN_BASE[0] = 3
  ZIP_LEN_BASE[1] = 4
  ZIP_LEN_BASE[2] = 5
  ZIP_LEN_BASE[3] = 6
  ZIP_LEN_BASE[4] = 7
  ZIP_LEN_BASE[5] = 8
  ZIP_LEN_BASE[6] = 9
  ZIP_LEN_BASE[7] = 10
  ZIP_LEN_BASE[8] = 11
  ZIP_LEN_BASE[9] = 13
  ZIP_LEN_BASE[10] = 15
  ZIP_LEN_BASE[11] = 17
  ZIP_LEN_BASE[12] = 19
  ZIP_LEN_BASE[13] = 23
  ZIP_LEN_BASE[14] = 27
  ZIP_LEN_BASE[15] = 31
  ZIP_LEN_BASE[16] = 35
  ZIP_LEN_BASE[17] = 43
  ZIP_LEN_BASE[18] = 51
  ZIP_LEN_BASE[19] = 59
  ZIP_LEN_BASE[20] = 67
  ZIP_LEN_BASE[21] = 83
  ZIP_LEN_BASE[22] = 99
  ZIP_LEN_BASE[23] = 115
  ZIP_LEN_BASE[24] = 131
  ZIP_LEN_BASE[25] = 163
  ZIP_LEN_BASE[26] = 195
  ZIP_LEN_BASE[27] = 227
  ZIP_LEN_BASE[28] = 258

  ZIP_LEN_EXTRA[0] = 0
  ZIP_LEN_EXTRA[1] = 0
  ZIP_LEN_EXTRA[2] = 0
  ZIP_LEN_EXTRA[3] = 0
  ZIP_LEN_EXTRA[4] = 0
  ZIP_LEN_EXTRA[5] = 0
  ZIP_LEN_EXTRA[6] = 0
  ZIP_LEN_EXTRA[7] = 0
  ZIP_LEN_EXTRA[8] = 1
  ZIP_LEN_EXTRA[9] = 1
  ZIP_LEN_EXTRA[10] = 1
  ZIP_LEN_EXTRA[11] = 1
  ZIP_LEN_EXTRA[12] = 2
  ZIP_LEN_EXTRA[13] = 2
  ZIP_LEN_EXTRA[14] = 2
  ZIP_LEN_EXTRA[15] = 2
  ZIP_LEN_EXTRA[16] = 3
  ZIP_LEN_EXTRA[17] = 3
  ZIP_LEN_EXTRA[18] = 3
  ZIP_LEN_EXTRA[19] = 3
  ZIP_LEN_EXTRA[20] = 4
  ZIP_LEN_EXTRA[21] = 4
  ZIP_LEN_EXTRA[22] = 4
  ZIP_LEN_EXTRA[23] = 4
  ZIP_LEN_EXTRA[24] = 5
  ZIP_LEN_EXTRA[25] = 5
  ZIP_LEN_EXTRA[26] = 5
  ZIP_LEN_EXTRA[27] = 5
  ZIP_LEN_EXTRA[28] = 0

  ZIP_DIST_BASE[0] = 1
  ZIP_DIST_BASE[1] = 2
  ZIP_DIST_BASE[2] = 3
  ZIP_DIST_BASE[3] = 4
  ZIP_DIST_BASE[4] = 5
  ZIP_DIST_BASE[5] = 7
  ZIP_DIST_BASE[6] = 9
  ZIP_DIST_BASE[7] = 13
  ZIP_DIST_BASE[8] = 17
  ZIP_DIST_BASE[9] = 25
  ZIP_DIST_BASE[10] = 33
  ZIP_DIST_BASE[11] = 49
  ZIP_DIST_BASE[12] = 65
  ZIP_DIST_BASE[13] = 97
  ZIP_DIST_BASE[14] = 129
  ZIP_DIST_BASE[15] = 193
  ZIP_DIST_BASE[16] = 257
  ZIP_DIST_BASE[17] = 385
  ZIP_DIST_BASE[18] = 513
  ZIP_DIST_BASE[19] = 769
  ZIP_DIST_BASE[20] = 1025
  ZIP_DIST_BASE[21] = 1537
  ZIP_DIST_BASE[22] = 2049
  ZIP_DIST_BASE[23] = 3073
  ZIP_DIST_BASE[24] = 4097
  ZIP_DIST_BASE[25] = 6145
  ZIP_DIST_BASE[26] = 8193
  ZIP_DIST_BASE[27] = 12289
  ZIP_DIST_BASE[28] = 16385
  ZIP_DIST_BASE[29] = 24577

  ZIP_DIST_EXTRA[0] = 0
  ZIP_DIST_EXTRA[1] = 0
  ZIP_DIST_EXTRA[2] = 0
  ZIP_DIST_EXTRA[3] = 0
  ZIP_DIST_EXTRA[4] = 1
  ZIP_DIST_EXTRA[5] = 1
  ZIP_DIST_EXTRA[6] = 2
  ZIP_DIST_EXTRA[7] = 2
  ZIP_DIST_EXTRA[8] = 3
  ZIP_DIST_EXTRA[9] = 3
  ZIP_DIST_EXTRA[10] = 4
  ZIP_DIST_EXTRA[11] = 4
  ZIP_DIST_EXTRA[12] = 5
  ZIP_DIST_EXTRA[13] = 5
  ZIP_DIST_EXTRA[14] = 6
  ZIP_DIST_EXTRA[15] = 6
  ZIP_DIST_EXTRA[16] = 7
  ZIP_DIST_EXTRA[17] = 7
  ZIP_DIST_EXTRA[18] = 8
  ZIP_DIST_EXTRA[19] = 8
  ZIP_DIST_EXTRA[20] = 9
  ZIP_DIST_EXTRA[21] = 9
  ZIP_DIST_EXTRA[22] = 10
  ZIP_DIST_EXTRA[23] = 10
  ZIP_DIST_EXTRA[24] = 11
  ZIP_DIST_EXTRA[25] = 11
  ZIP_DIST_EXTRA[26] = 12
  ZIP_DIST_EXTRA[27] = 12
  ZIP_DIST_EXTRA[28] = 13
  ZIP_DIST_EXTRA[29] = 13

  ZIP_CL_ORDER[0] = 16
  ZIP_CL_ORDER[1] = 17
  ZIP_CL_ORDER[2] = 18
  ZIP_CL_ORDER[3] = 0
  ZIP_CL_ORDER[4] = 8
  ZIP_CL_ORDER[5] = 7
  ZIP_CL_ORDER[6] = 9
  ZIP_CL_ORDER[7] = 6
  ZIP_CL_ORDER[8] = 10
  ZIP_CL_ORDER[9] = 5
  ZIP_CL_ORDER[10] = 11
  ZIP_CL_ORDER[11] = 4
  ZIP_CL_ORDER[12] = 12
  ZIP_CL_ORDER[13] = 3
  ZIP_CL_ORDER[14] = 13
  ZIP_CL_ORDER[15] = 2
  ZIP_CL_ORDER[16] = 14
  ZIP_CL_ORDER[17] = 1
  ZIP_CL_ORDER[18] = 15
  ZIP_TABLES_READY = 1
}

# --------------------------------------------------------------- DEFLATE bit writer

fn zip_bw_init(cap: int) {
  ZIP_BW = newbuf(cap)
  ZIP_BW_CAP = cap
  ZIP_BW_LEN = 0
  ZIP_BW_BITS = 0
  ZIP_BW_NBITS = 0
}

# Non-Huffman fields are packed least-significant bit first (RFC 1951 3.1.1).
fn zip_bw_put(value: int, count: int) {
  if ZIP_BW_BAD == 1 || count <= 0 {
    return
  }
  ZIP_BW_BITS = ZIP_BW_BITS | ((value & ((1 << count) - 1)) << ZIP_BW_NBITS)
  ZIP_BW_NBITS = ZIP_BW_NBITS + count
  while ZIP_BW_NBITS >= 8 {
    if ZIP_BW_LEN >= ZIP_BW_CAP {
      ZIP_BW_BAD = 1
      return
    }
    ZIP_BW[ZIP_BW_LEN] = ZIP_BW_BITS & 255
    ZIP_BW_LEN = ZIP_BW_LEN + 1
    ZIP_BW_BITS = ZIP_BW_BITS >> 8
    ZIP_BW_NBITS = ZIP_BW_NBITS - 8
  }
}

fn zip_bw_flush() {
  if ZIP_BW_BAD == 1 {
    return
  }
  if ZIP_BW_NBITS > 0 {
    if ZIP_BW_LEN >= ZIP_BW_CAP {
      ZIP_BW_BAD = 1
      return
    }
    ZIP_BW[ZIP_BW_LEN] = ZIP_BW_BITS & 255
    ZIP_BW_LEN = ZIP_BW_LEN + 1
  }
  ZIP_BW_BITS = 0
  ZIP_BW_NBITS = 0
}

fn zip_reverse_bits(code: int, count: int) -> int {
  let out = 0
  let i = 0
  while i < count {
    out = (out << 1) | (code & 1)
    code = code >> 1
    i = i + 1
  }
  return out
}

# Fixed literal/length codes: lengths 8/9/7/8 for the four ranges, and the
# canonical values from RFC 1951 3.2.6. Huffman codes are packed MSB first, so
# reverse them before the LSB-first writer.
fn zip_emit_lit(sym: int) {
  let code = 0
  let bits = 0
  if sym <= 143 {
    code = 0x30 + sym
    bits = 8
  } else if sym <= 255 {
    code = 0x190 + (sym - 144)
    bits = 9
  } else if sym <= 279 {
    code = sym - 256
    bits = 7
  } else {
    code = 0xC0 + (sym - 280)
    bits = 8
  }
  zip_bw_put(zip_reverse_bits(code, bits), bits)
}

fn zip_len_code(length: int) -> int {
  let i = 28
  while i > 0 {
    if length >= ZIP_LEN_BASE[i] {
      return i
    }
    i = i - 1
  }
  return 0
}

fn zip_dist_code(dist: int) -> int {
  let i = 29
  while i > 0 {
    if dist >= ZIP_DIST_BASE[i] {
      return i
    }
    i = i - 1
  }
  return 0
}

fn zip_emit_match(length: int, dist: int) {
  let li = zip_len_code(length)
  zip_emit_lit(257 + li)
  let le = ZIP_LEN_EXTRA[li]
  if le > 0 {
    zip_bw_put(length - ZIP_LEN_BASE[li], le)
  }
  let di = zip_dist_code(dist)
  zip_bw_put(zip_reverse_bits(di, 5), 5)
  let de = ZIP_DIST_EXTRA[di]
  if de > 0 {
    zip_bw_put(dist - ZIP_DIST_BASE[di], de)
  }
}

# --------------------------------------------------------------- DEFLATE bit reader

fn zip_br_init(src: str, off: int, n: int) {
  ZIP_IN = src
  ZIP_IN_POS = off
  ZIP_IN_END = off + n
  ZIP_IN_BITS = 0
  ZIP_IN_NBITS = 0
  ZIP_IN_BAD = 0
}

fn zip_br_bits(count: int) -> int {
  if count <= 0 {
    return 0
  }
  while ZIP_IN_NBITS < count {
    if ZIP_IN_POS >= ZIP_IN_END {
      ZIP_IN_BAD = 1
      return 0
    }
    ZIP_IN_BITS = ZIP_IN_BITS | ((ZIP_IN[ZIP_IN_POS] & 255) << ZIP_IN_NBITS)
    ZIP_IN_POS = ZIP_IN_POS + 1
    ZIP_IN_NBITS = ZIP_IN_NBITS + 8
  }
  let value = ZIP_IN_BITS & ((1 << count) - 1)
  ZIP_IN_BITS = ZIP_IN_BITS >> count
  ZIP_IN_NBITS = ZIP_IN_NBITS - count
  return value
}

# Stored blocks start on the next byte boundary. Prefetched whole bytes stay in
# the bit buffer; only the partially consumed current byte is discarded.
fn zip_br_align() {
  let drop = ZIP_IN_NBITS % 8
  if drop > 0 {
    ZIP_IN_BITS = ZIP_IN_BITS >> drop
    ZIP_IN_NBITS = ZIP_IN_NBITS - drop
  }
}

fn zip_br_u16() -> int {
  let lo = zip_br_bits(8)
  let hi = zip_br_bits(8)
  return lo | (hi << 8)
}

# --------------------------------------------------------------- DEFLATE Huffman

fn zip_h_build(which: int, n: int) -> int {
  let base = which * 288
  let cbase = which * 16
  for i in 0..16 {
    ZIP_H_COUNTS[cbase + i] = 0
  }
  for i in 0..n {
    let len = ZIP_H_LENS[base + i]
    if len < 0 || len > 15 {
      return 0
    }
    ZIP_H_COUNTS[cbase + len] = ZIP_H_COUNTS[cbase + len] + 1
  }
  # Unused symbols do not participate in the canonical code assignment. Their
  # count must be cleared before computing next_code, or every dynamic code is
  # shifted by the number of absent symbols (RFC 1951 3.2.2 step 2).
  ZIP_H_COUNTS[cbase] = 0
  # A complete prefix code leaves no unused code space. A single distance code
  # of length one is deliberately allowed to leave one unused code.
  let left = 1
  for bits in 1..16 {
    left = (left << 1) - ZIP_H_COUNTS[cbase + bits]
    if left < 0 {
      return 0
    }
  }
  let code = 0
  let pos = 0
  for bits in 1..16 {
    code = (code + ZIP_H_COUNTS[cbase + bits - 1]) << 1
    ZIP_H_FIRST[cbase + bits] = code
    ZIP_H_OFF[cbase + bits] = pos
    pos = pos + ZIP_H_COUNTS[cbase + bits]
  }
  let k = 0
  for bits in 1..16 {
    for sym in 0..n {
      if ZIP_H_LENS[base + sym] == bits {
        ZIP_H_SYMS[base + k] = sym
        k = k + 1
      }
    }
  }
  return 1
}

# Walk the canonical code one bit at a time in MSB-first order. The codes are
# consecutive within each length, so a subtraction finds the symbol.
fn zip_h_decode(which: int) -> int {
  if ZIP_IN_BAD == 1 {
    return -1
  }
  let base = which * 288
  let cbase = which * 16
  let code = 0
  for bits in 1..16 {
    code = (code << 1) | zip_br_bits(1)
    if ZIP_IN_BAD == 1 {
      return -1
    }
    let count = ZIP_H_COUNTS[cbase + bits]
    if count > 0 {
      let delta = code - ZIP_H_FIRST[cbase + bits]
      if delta >= 0 && delta < count {
        return ZIP_H_SYMS[base + ZIP_H_OFF[cbase + bits] + delta]
      }
    }
  }
  ZIP_IN_BAD = 1
  return -1
}

fn zip_h_fixed() -> int {
  for i in 0..288 {
    let len = 8
    if i <= 143 {
      len = 8
    } else if i <= 255 {
      len = 9
    } else if i <= 279 {
      len = 7
    }
    ZIP_H_LENS[i] = len
  }
  for i in 0..32 {
    ZIP_H_LENS[288 + i] = 5
  }
  if zip_h_build(0, 288) == 0 {
    return 0
  }
  return zip_h_build(1, 32)
}

# ------------------------------------------------------------------ DEFLATE inflate

fn zip_inflate_dynamic() -> int {
  let hlit = zip_br_bits(5) + 257
  let hdist = zip_br_bits(5) + 1
  let hclen = zip_br_bits(4) + 4
  if ZIP_IN_BAD == 1 || hlit > 286 || hdist > 32 || hclen > 19 {
    ZIP_IN_BAD = 1
    return 0
  }
  for i in 0..19 {
    ZIP_H_LENS[576 + i] = 0
  }
  for i in 0..hclen {
    ZIP_H_LENS[576 + ZIP_CL_ORDER[i]] = zip_br_bits(3)
  }
  if ZIP_IN_BAD == 1 || zip_h_build(2, 19) == 0 {
    ZIP_IN_BAD = 1
    return 0
  }
  let total = hlit + hdist
  for i in 0..total {
    ZIP_DYN_LENS[i] = 0
  }
  let i = 0
  while i < total {
    let sym = zip_h_decode(2)
    if sym < 0 {
      return 0
    }
    if sym <= 15 {
      ZIP_DYN_LENS[i] = sym
      i = i + 1
    } else if sym == 16 {
      if i == 0 {
        ZIP_IN_BAD = 1
        return 0
      }
      let rep = zip_br_bits(2) + 3
      if ZIP_IN_BAD == 1 || i + rep > total {
        ZIP_IN_BAD = 1
        return 0
      }
      let prev = ZIP_DYN_LENS[i - 1]
      for j in 0..rep {
        ZIP_DYN_LENS[i + j] = prev
      }
      i = i + rep
    } else if sym == 17 {
      let rep = zip_br_bits(3) + 3
      if ZIP_IN_BAD == 1 || i + rep > total {
        ZIP_IN_BAD = 1
        return 0
      }
      i = i + rep
    } else if sym == 18 {
      let rep = zip_br_bits(7) + 11
      if ZIP_IN_BAD == 1 || i + rep > total {
        ZIP_IN_BAD = 1
        return 0
      }
      i = i + rep
    } else {
      ZIP_IN_BAD = 1
      return 0
    }
  }
  for i in 0..hlit {
    ZIP_H_LENS[i] = ZIP_DYN_LENS[i]
  }
  for i in 0..hdist {
    ZIP_H_LENS[288 + i] = ZIP_DYN_LENS[hlit + i]
  }
  if zip_h_build(0, hlit) == 0 || zip_h_build(1, hdist) == 0 {
    ZIP_IN_BAD = 1
    return 0
  }
  if ZIP_H_LENS[256] == 0 {
    ZIP_IN_BAD = 1
    return 0
  }
  return 1
}

fn zip_inflate_codes() -> int {
  while 1 == 1 {
    let sym = zip_h_decode(0)
    if sym < 0 {
      return 0
    }
    if sym < 256 {
      if ZIP_OUT_POS >= ZIP_OUT_SIZE {
        ZIP_IN_BAD = 1
        return 0
      }
      ZIP_OUT[ZIP_OUT_POS] = sym
      ZIP_OUT_POS = ZIP_OUT_POS + 1
    } else if sym == 256 {
      return 1
    } else if sym <= 285 {
      let li = sym - 257
      let len = ZIP_LEN_BASE[li] + zip_br_bits(ZIP_LEN_EXTRA[li])
      let ds = zip_h_decode(1)
      if ds < 0 || ds > 29 || ZIP_IN_BAD == 1 {
        ZIP_IN_BAD = 1
        return 0
      }
      let dist = ZIP_DIST_BASE[ds] + zip_br_bits(ZIP_DIST_EXTRA[ds])
      if ZIP_IN_BAD == 1 || dist <= 0 || dist > ZIP_OUT_POS {
        ZIP_IN_BAD = 1
        return 0
      }
      if ZIP_OUT_POS + len > ZIP_OUT_SIZE {
        ZIP_IN_BAD = 1
        return 0
      }
      for j in 0..len {
        ZIP_OUT[ZIP_OUT_POS] = ZIP_OUT[ZIP_OUT_POS - dist]
        ZIP_OUT_POS = ZIP_OUT_POS + 1
      }
    } else {
      ZIP_IN_BAD = 1
      return 0
    }
  }
}

fn zip_inflate(src: str, off: int, comp_len: int, size: int) -> str {
  if size < 0 || comp_len < 0 || off < 0 || off + comp_len > ZIP_LEN {
    ZIP_ERR = ZIP_E_FORMAT
    return ""
  }
  zip_tables_init()
  zip_br_init(src, off, comp_len)
  let out = newbuf(size)
  ZIP_OUT = out
  ZIP_OUT_POS = 0
  ZIP_OUT_SIZE = size
  let final = 0
  while final == 0 && ZIP_IN_BAD == 0 {
    final = zip_br_bits(1)
    let btype = zip_br_bits(2)
    if ZIP_IN_BAD == 1 {
      break
    }
    if btype == 0 {
      zip_br_align()
      let len = zip_br_u16()
      let nlen = zip_br_u16()
      if ZIP_IN_BAD == 1 || (len ^ 65535) != nlen {
        ZIP_IN_BAD = 1
        break
      }
      if ZIP_OUT_POS + len > ZIP_OUT_SIZE {
        ZIP_IN_BAD = 1
        break
      }
      for j in 0..len {
        ZIP_OUT[ZIP_OUT_POS] = zip_br_bits(8)
        ZIP_OUT_POS = ZIP_OUT_POS + 1
      }
    } else if btype == 1 {
      if zip_h_fixed() == 0 || zip_inflate_codes() == 0 {
        ZIP_IN_BAD = 1
        break
      }
    } else if btype == 2 {
      if zip_inflate_dynamic() == 0 || zip_inflate_codes() == 0 {
        ZIP_IN_BAD = 1
        break
      }
    } else {
      ZIP_IN_BAD = 1
      break
    }
  }
  if ZIP_IN_BAD == 1 || ZIP_OUT_POS != size {
    free(out)
    ZIP_OUT = ""
    ZIP_ERR = ZIP_E_FORMAT
    return ""
  }
  ZIP_OUT = ""
  if size == 0 {
    free(out)
    return ""
  }
  return out
}

# ------------------------------------------------------------------ DEFLATE compress

fn zip_hash_insert(data: str, n: int, pos: int) {
  if pos + 2 >= n {
    return
  }
  let hash = ((data[pos] & 255) * 251 + (data[pos + 1] & 255)) * 251 + (data[pos + 2] & 255)
  let base = (hash & 4095) * 4
  ZIP_HASH[base + 3] = ZIP_HASH[base + 2]
  ZIP_HASH[base + 2] = ZIP_HASH[base + 1]
  ZIP_HASH[base + 1] = ZIP_HASH[base]
  ZIP_HASH[base] = pos
}

fn zip_find_match(data: str, n: int, pos: int) -> int {
  ZIP_MATCH_DIST = 0
  if pos + 2 >= n {
    return 0
  }
  let hash = ((data[pos] & 255) * 251 + (data[pos + 1] & 255)) * 251 + (data[pos + 2] & 255)
  let base = (hash & 4095) * 4
  let best = 0
  let max = n - pos
  if max > 258 {
    max = 258
  }
  for slot in 0..4 {
    let cand = ZIP_HASH[base + slot]
    if cand >= 0 && cand < pos && pos - cand <= 32768 {
      if data[cand] == data[pos] && data[cand + 1] == data[pos + 1] && data[cand + 2] == data[pos + 2] {
        let len = 3
        while len < max && data[cand + len] == data[pos + len] {
          len = len + 1
        }
        if len > best {
          best = len
          ZIP_MATCH_DIST = pos - cand
          if best == max {
            return best
          }
        }
      }
    }
  }
  return best
}

fn zip_deflate(data: str, n: int) -> str {
  zip_tables_init()
  ZIP_BW_BAD = 0
  let cap = n + n / 8 + 64
  zip_bw_init(cap)
  for i in 0..16384 {
    ZIP_HASH[i] = -1
  }
  zip_bw_put(1, 1)              # BFINAL
  zip_bw_put(1, 2)              # BTYPE 01: fixed Huffman
  let pos = 0
  while pos < n && ZIP_BW_BAD == 0 {
    let len = zip_find_match(data, n, pos)
    if len >= 3 && ZIP_MATCH_DIST > 0 {
      zip_emit_match(len, ZIP_MATCH_DIST)
      for j in 0..len {
        zip_hash_insert(data, n, pos + j)
      }
      pos = pos + len
    } else {
      zip_emit_lit(data[pos] & 255)
      zip_hash_insert(data, n, pos)
      pos = pos + 1
    }
  }
  if ZIP_BW_BAD == 0 {
    zip_emit_lit(256)           # end of block
    zip_bw_flush()
  }
  return ZIP_BW
}

# --------------------------------------------------------------------- reading

fn zip_find_eocd() -> int {
  if ZIP_LEN < 22 {
    return -1
  }
  let stop = 0
  if ZIP_LEN > 65557 {
    stop = ZIP_LEN - 65557
  }
  let i = ZIP_LEN - 22
  while i >= stop {
    if ld32(ZIP_SRC, i) == 0x06054B50 {
      return i
    }
    i = i - 1
  }
  return -1
}

fn zip_clear() {
  ZIP_COUNT = 0
  ZIP_LEN = 0
  ZIP_SRC = ""
  ZIP_ERR = ZIP_OK
}

# Load the central directory of `path`. Returns the entry count, or -1 with
# ZIP_ERR set. The archive stays in ZIP_SRC until the next zip_open.
fn zip_open(path: str) -> int {
  zip_clear()
  let src = read_file(path)
  let len = file_size(path)
  if len <= 0 {
    ZIP_ERR = ZIP_E_IO
    return -1
  }
  ZIP_SRC = src
  ZIP_LEN = len
  let eocd = zip_find_eocd()
  if eocd < 0 {
    ZIP_ERR = ZIP_E_FORMAT
    return -1
  }
  let count = ld16(ZIP_SRC, eocd + 10)
  let cd_size = ld32(ZIP_SRC, eocd + 12)
  let cd_offset = ld32(ZIP_SRC, eocd + 16)
  if count == 65535 || cd_size == 0xFFFFFFFF || cd_offset == 0xFFFFFFFF {
    ZIP_ERR = ZIP_E_FORMAT       # ZIP64, which this reader does not implement
    return -1
  }
  if cd_offset + cd_size > ZIP_LEN {
    ZIP_ERR = ZIP_E_FORMAT
    return -1
  }
  if count > ZIP_MAX_ENTRIES {
    ZIP_ERR = ZIP_E_LIMIT
    return -1
  }
  let p = cd_offset
  for i in 0..count {
    if p + 46 > ZIP_LEN || ld32(ZIP_SRC, p) != 0x02014B50 {
      ZIP_ERR = ZIP_E_FORMAT
      return -1
    }
    let flags = ld16(ZIP_SRC, p + 8)
    let method = ld16(ZIP_SRC, p + 10)
    let crc = ld32(ZIP_SRC, p + 16)
    let comp_size = ld32(ZIP_SRC, p + 20)
    let size = ld32(ZIP_SRC, p + 24)
    let name_len = ld16(ZIP_SRC, p + 28)
    let extra_len = ld16(ZIP_SRC, p + 30)
    let comment_len = ld16(ZIP_SRC, p + 32)
    let local = ld32(ZIP_SRC, p + 42)
    if flags & 1 {
      ZIP_ERR = ZIP_E_FORMAT       # encrypted
      return -1
    }
    if method == 0 && comp_size != size {
      ZIP_ERR = ZIP_E_FORMAT       # stored entries must have equal sizes
      return -1
    }
    if comp_size == 0xFFFFFFFF || size == 0xFFFFFFFF || local == 0xFFFFFFFF {
      ZIP_ERR = ZIP_E_FORMAT       # ZIP64
      return -1
    }
    if p + 46 + name_len > ZIP_LEN {
      ZIP_ERR = ZIP_E_FORMAT
      return -1
    }
    if local + 30 > ZIP_LEN || ld32(ZIP_SRC, local) != 0x04034B50 {
      ZIP_ERR = ZIP_E_FORMAT
      return -1
    }
    let local_name = ld16(ZIP_SRC, local + 26)
    let local_extra = ld16(ZIP_SRC, local + 28)
    let data_offset = local + 30 + local_name + local_extra
    if data_offset + comp_size > ZIP_LEN {
      ZIP_ERR = ZIP_E_FORMAT
      return -1
    }
    ZIP_NAMES[i] = zip_copy_bytes(ZIP_SRC, p + 46, name_len)
    ZIP_METHODS[i] = method
    ZIP_CRCS[i] = crc
    ZIP_COMP_SIZES[i] = comp_size
    ZIP_SIZES[i] = size
    ZIP_DATA_OFFSETS[i] = data_offset
    ZIP_COUNT = i + 1
    p = p + 46 + name_len + extra_len + comment_len
  }
  return ZIP_COUNT
}

fn zip_name(index: int) -> str {
  if index < 0 || index >= ZIP_COUNT {
    return ""
  }
  return ZIP_NAMES[index]
}

fn zip_size(index: int) -> int {
  if index < 0 || index >= ZIP_COUNT {
    return 0
  }
  return ZIP_SIZES[index]
}

fn zip_compressed_size(index: int) -> int {
  if index < 0 || index >= ZIP_COUNT {
    return 0
  }
  return ZIP_COMP_SIZES[index]
}

fn zip_method(index: int) -> int {
  if index < 0 || index >= ZIP_COUNT {
    return -1
  }
  return ZIP_METHODS[index]
}

fn zip_crc(index: int) -> int {
  if index < 0 || index >= ZIP_COUNT {
    return 0
  }
  return ZIP_CRCS[index]
}

# Return the uncompressed bytes of a stored or deflated entry, or "" with
# ZIP_ERR set when the entry is out of range or the archive is inconsistent.
# The CRC is checked here so zip_list and zip_extract reject the same bytes.
fn zip_data(index: int) -> str {
  if index < 0 || index >= ZIP_COUNT {
    ZIP_ERR = ZIP_E_ARG
    return ""
  }
  let method = ZIP_METHODS[index]
  if method != 0 && method != 8 {
    ZIP_ERR = ZIP_E_METHOD
    return ""
  }
  ZIP_ERR = ZIP_OK
  let offset = ZIP_DATA_OFFSETS[index]
  let comp = ZIP_COMP_SIZES[index]
  let size = ZIP_SIZES[index]
  if offset + comp > ZIP_LEN {
    ZIP_ERR = ZIP_E_FORMAT
    return ""
  }
  let data = ""
  if method == 0 {
    data = zip_copy_bytes(ZIP_SRC, offset, size)
  } else {
    data = zip_inflate(ZIP_SRC, offset, comp, size)
    if ZIP_ERR != ZIP_OK {
      return ""
    }
  }
  if zip_crc32(data, size) != ZIP_CRCS[index] {
    if size > 0 {
      free(data)
    }
    ZIP_ERR = ZIP_E_FORMAT
    return ""
  }
  return data
}

# Write one entry to `path`, truncating it. Both stored and deflated entries
# round-trip binary data exactly because fd_write takes an explicit byte count.
fn zip_extract(index: int, path: str) -> int {
  if index < 0 || index >= ZIP_COUNT {
    ZIP_ERR = ZIP_E_ARG
    return 0
  }
  let data = zip_data(index)
  if ZIP_ERR != ZIP_OK {
    return 0
  }
  let size = ZIP_SIZES[index]
  let fd = open_fd(path, 1 + 64 + 512)
  if fd < 0 {
    if size > 0 {
      free(data)
    }
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  if size > 0 && fd_write(fd, data, size) != size {
    close_fd(fd)
    free(data)
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  if close_fd(fd) != 0 {
    if size > 0 {
      free(data)
    }
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  if size > 0 {
    free(data)
  }
  return 1
}

# --------------------------------------------------------------------- writing

# Open `path` for a new archive. Existing archives are truncated.
fn zip_create(path: str) -> int {
  if ZIP_FD >= 0 {
    ZIP_ERR = ZIP_E_ARG
    return 0
  }
  ZIP_ERR = ZIP_OK
  ZIP_COUNT = 0
  ZIP_POS = 0
  let fd = open_fd(path, 1 + 64 + 512)
  if fd < 0 {
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  ZIP_FD = fd
  return 1
}

# Append an entry. `n` is the exact byte count, so `data` may contain NUL.
# DEFLATE is used only when it makes the entry smaller; otherwise the original
# bytes are written with method 0. This keeps tiny or incompressible files from
# growing because of the block header.
fn zip_add(name: str, data: str, n: int) -> int {
  if ZIP_FD < 0 {
    ZIP_ERR = ZIP_E_ARG
    return 0
  }
  let name_len = len(name)
  if n < 0 || name_len <= 0 || name_len > 65535 {
    ZIP_ERR = ZIP_E_ARG
    return 0
  }
  if ZIP_COUNT >= ZIP_MAX_ENTRIES {
    ZIP_ERR = ZIP_E_LIMIT
    return 0
  }
  let crc = zip_crc32(data, n)
  let deflated = zip_deflate(data, n)
  let method = 8
  let comp = deflated
  let comp_len = ZIP_BW_LEN
  if ZIP_BW_BAD == 1 || comp_len >= n {
    method = 0
    comp = data
    comp_len = n
  }
  let header = newbuf(30 + name_len)
  zip_put32(header, 0, 0x04034B50)
  zip_put16(header, 4, 20)          # version needed: 2.0
  zip_put16(header, 6, 0x0800)      # names are UTF-8
  zip_put16(header, 8, method)
  zip_put16(header, 10, 0)          # DOS time 00:00
  zip_put16(header, 12, 0x21)       # DOS date 1980-01-01
  zip_put32(header, 14, crc)
  zip_put32(header, 18, comp_len)
  zip_put32(header, 22, n)
  zip_put16(header, 26, name_len)
  zip_put16(header, 28, 0)
  zip_copy_name(header, 30, name, name_len)

  let offset = ZIP_POS
  let wrote = fd_write(ZIP_FD, header, 30 + name_len)
  if wrote != 30 + name_len {
    free(deflated)
    ZIP_BW = ""
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  if comp_len > 0 && fd_write(ZIP_FD, comp, comp_len) != comp_len {
    free(deflated)
    ZIP_BW = ""
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  free(deflated)
  ZIP_BW = ""
  ZIP_NAMES_OUT[ZIP_COUNT] = slice(name, 0, name_len)
  ZIP_SIZES_OUT[ZIP_COUNT] = n
  ZIP_COMP_SIZES_OUT[ZIP_COUNT] = comp_len
  ZIP_CRCS_OUT[ZIP_COUNT] = crc
  ZIP_METHODS_OUT[ZIP_COUNT] = method
  ZIP_OFFSETS_OUT[ZIP_COUNT] = offset
  ZIP_COUNT = ZIP_COUNT + 1
  ZIP_POS = ZIP_POS + 30 + name_len + comp_len
  return 1
}

fn zip_add_file(name: str, path: str) -> int {
  let n = file_size(path)
  if n < 0 {
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  let data = read_file(path)
  return zip_add(name, data, n)
}

# Write the central directory and end-of-central-directory record, then close.
fn zip_finish() -> int {
  if ZIP_FD < 0 {
    ZIP_ERR = ZIP_E_ARG
    return 0
  }
  let cd_start = ZIP_POS
  for i in 0..ZIP_COUNT {
    let name = ZIP_NAMES_OUT[i]
    let name_len = len(name)
    let size = ZIP_SIZES_OUT[i]
    let comp = ZIP_COMP_SIZES_OUT[i]
    let header = newbuf(46 + name_len)
    zip_put32(header, 0, 0x02014B50)
    zip_put16(header, 4, 20)        # version made by
    zip_put16(header, 6, 20)        # version needed
    zip_put16(header, 8, 0x0800)
    zip_put16(header, 10, ZIP_METHODS_OUT[i])
    zip_put16(header, 12, 0)
    zip_put16(header, 14, 0x21)
    zip_put32(header, 16, ZIP_CRCS_OUT[i])
    zip_put32(header, 20, comp)
    zip_put32(header, 24, size)
    zip_put16(header, 28, name_len)
    zip_put16(header, 30, 0)
    zip_put16(header, 32, 0)
    zip_put16(header, 34, 0)
    zip_put16(header, 36, 0)
    zip_put32(header, 38, 0)
    zip_put32(header, 42, ZIP_OFFSETS_OUT[i])
    zip_copy_name(header, 46, name, name_len)
    if fd_write(ZIP_FD, header, 46 + name_len) != 46 + name_len {
      ZIP_ERR = ZIP_E_IO
      return 0
    }
    ZIP_POS = ZIP_POS + 46 + name_len
  }
  let eocd = newbuf(22)
  zip_put32(eocd, 0, 0x06054B50)
  zip_put16(eocd, 4, 0)
  zip_put16(eocd, 6, 0)
  zip_put16(eocd, 8, ZIP_COUNT)
  zip_put16(eocd, 10, ZIP_COUNT)
  zip_put32(eocd, 12, ZIP_POS - cd_start)
  zip_put32(eocd, 16, cd_start)
  zip_put16(eocd, 20, 0)
  if fd_write(ZIP_FD, eocd, 22) != 22 {
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  if close_fd(ZIP_FD) != 0 {
    ZIP_FD = -1
    ZIP_ERR = ZIP_E_IO
    return 0
  }
  ZIP_FD = -1
  ZIP_POS = ZIP_POS + 22
  return 1
}

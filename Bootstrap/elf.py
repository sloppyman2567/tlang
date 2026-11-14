"""Post-link ELF surgery: drop the parts the kernel never reads.

Section headers and the section-name table exist for tools (objdump, gdb,
`strip`), not for the loader -- Linux runs a binary using the program headers
alone.  On a tlang-sized binary they are the single largest remaining cost:
384 bytes of headers plus ~47 bytes of names, about 45% of a hello world.

Deleting them is exactly what `sstrip` does; the only downside is that
section-aware tools will report the file as having no sections.
"""

import struct

# ident, e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
# e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx
ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
PROGRAM_HEADER = struct.Struct("<IIQQQQQQ")
PT_LOAD = 1

E_SHOFF_OFF = 0x28
E_SHNUM_OFF = 0x3C          # e_shnum and e_shstrndx are adjacent


class ElfError(Exception):
    pass


def strip_sections(path):
    """Truncate `path` to its loaded bytes and forget its section headers.

    Returns the new size in bytes.
    """
    with open(path, "rb") as fh:
        data = bytearray(fh.read())

    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise ElfError(f"{path}: not a 64-bit ELF file")

    header = ELF_HEADER.unpack_from(data, 0)
    e_phoff, e_shoff = header[5], header[6]
    e_phentsize, e_phnum = header[9], header[10]

    if e_shoff == 0:                        # already stripped
        return len(data)

    # The last byte anything will read: the furthest end of a PT_LOAD segment.
    end = 0
    for index in range(e_phnum):
        offset = e_phoff + index * e_phentsize
        fields = PROGRAM_HEADER.unpack_from(data, offset)
        if fields[0] != PT_LOAD:
            continue
        p_offset, p_filesz = fields[2], fields[5]
        end = max(end, p_offset + p_filesz)

    if end == 0 or end > len(data):
        raise ElfError(f"{path}: no loadable segment found")

    del data[end:]
    struct.pack_into("<Q", data, E_SHOFF_OFF, 0)
    struct.pack_into("<HH", data, E_SHNUM_OFF, 0, 0)   # e_shnum, e_shstrndx

    with open(path, "wb") as fh:
        fh.write(data)
    return len(data)


if __name__ == "__main__":       # python3 -m Bootstrap.elf BINARY...
    import sys

    for name in sys.argv[1:]:
        size = strip_sections(name)
        print(f"tstrip: {name} ({size} bytes)")

"""Single source of truth for builtin names, IDs, signatures and runtime symbols.

Fields: name, id, arity, result kind, runtime symbol, allowed argument kinds,
and whether stage 0 exposes the builtin through its generic BUILTINS table.
`len` is handled specially by stage 0 and has no generic entry here.
"""

BUILTIN_SPECS = (
    ("print", 1, 1, "int", "__t_print", (("str", "int"),), True),
    ("print_err", 2, 1, "int", "__t_print_err", (("str", "int"),), True),
    ("print_int", 3, 1, "int", "__t_print_int", (("int",),), True),
    ("print_char", 4, 1, "int", "__t_print_char", (("int",),), True),
    ("input", 5, 0, "str", "__t_input", None, True),
    ("int", 6, 1, "int", "__t_int", (("str", "float"),), True),
    ("str", 7, 1, "str", "__t_itoa", (("int", "float"),), True),
    ("len", 8, 1, "int", "__t_strlen", None, False),
    ("slice", 9, 3, "str", "__t_slice", (("str",), ("int",), ("int",)), True),
    ("str_eq", 10, 2, "int", "__t_str_eq", (("str",), ("str",)), True),
    ("alloc", 11, 1, "ptr", "__t_alloc", (("int",),), True),
    ("read_file", 12, 1, "str", "__t_read_file", (("str",),), True),
    ("argv", 13, 1, "str", "__t_argv", (("int",),), True),
    ("argc", 14, 0, "int", "__t_argc", (), True),
    ("exit", 15, 1, "int", "__t_exit", (("int",),), True),
    ("append", 16, 2, "ptr", "__t_append", None, True),
    ("file_size", 17, 1, "int", "__t_file_size", (("str",),), True),
    ("sock", 18, 1, "int", "__t_sock_unix", (("str",),), True),
    ("fd_read", 19, 3, "int", "__t_fd_read",
     (("int",), ("str",), ("int",)), True),
    ("fd_write", 20, 3, "int", "__t_fd_write",
     (("int",), ("str",), ("int",)), True),
    ("fd_poll", 21, 2, "int", "__t_fd_poll", (("int",), ("int",)), True),
    ("newbuf", 22, 1, "str", "__t_newbuf", (("int",),), True),
    ("arena_mark", 23, 0, "int", "__t_arena_mark", None, True),
    ("arena_release", 24, 1, "int", "__t_arena_release", (("int",),), True),
    ("write_file", 25, 2, "int", "__t_write_file",
     (("str",), ("str",)), True),
    ("append_file", 26, 2, "int", "__t_append_file",
     (("str",), ("str",)), True),
    ("file_exists", 27, 1, "int", "__t_file_exists", (("str",),), True),
    ("float", 28, 1, "float", "__t_itof", (("int", "float"),), True),
    ("print_float", 29, 1, "int", "__t_print_float", (("float",),), True),
    ("sqrt", 30, 1, "float", "__t_fsqrt", (("float",),), True),
    ("fabs", 31, 1, "float", "__t_fabs", (("float",),), True),
    ("shm", 32, 1, "int", "__t_shm", (("int",),), True),
    ("fd_pwrite", 33, 4, "int", "__t_fd_pwrite",
     (("int",), ("int",), ("str",), ("int",)), True),
    ("fd_send", 34, 4, "int", "__t_fd_send",
     (("int",), ("str",), ("int",), ("int",)), True),
    ("str_offset", 35, 2, "str", "__t_str_offset",
     (("str",), ("int",)), True),
    ("str_diff", 36, 2, "int", "__t_str_diff", (("str",), ("str",)), True),
    # Environment lookup reads the strings the kernel placed after argv, so
    # it depends on the "args" capture and returns "" for an unset name.
    ("env", 72, 1, "str", "__t_env", (("str",),), True),
    # Bit primitives for emulators: they replace hand-written loops that undo
    # the lack of unsigned types, byte swapping and carry flags in tlang.
    ("clz", 73, 1, "int", "__t_clz", (("int",),), True),
    ("rbit", 74, 1, "int", "__t_rbit", (("int",),), True),
    ("bswap16", 75, 1, "int", "__t_bswap16", (("int",),), True),
    ("bswap32", 76, 1, "int", "__t_bswap32", (("int",),), True),
    ("bswap64", 77, 1, "int", "__t_bswap64", (("int",),), True),
    ("sext8", 78, 1, "int", "__t_sext8", (("int",),), True),
    ("sext16", 79, 1, "int", "__t_sext16", (("int",),), True),
    ("sext32", 80, 1, "int", "__t_sext32", (("int",),), True),
    ("udiv", 81, 2, "int", "__t_udiv", (("int",), ("int",)), True),
    ("umod", 82, 2, "int", "__t_umod", (("int",), ("int",)), True),
    ("rol8", 83, 2, "int", "__t_rol8", (("int",), ("int",)), True),
    ("ror8", 84, 2, "int", "__t_ror8", (("int",), ("int",)), True),
    # Unchecked byte-addressed access into a newbuf/nul-terminated buffer, with
    # explicit little-endian widths.  These are the primitives an emulator's
    # guest-memory helpers are made of; the index checks are deliberately not
    # repeated here, so --no-bounds is not needed for the hot path.
    ("ld8", 85, 2, "int", "__t_ld8", (("str",), ("int",)), True),
    ("ld16", 86, 2, "int", "__t_ld16", (("str",), ("int",)), True),
    ("ld32", 87, 2, "int", "__t_ld32", (("str",), ("int",)), True),
    ("ld64", 88, 2, "int", "__t_ld64", (("str",), ("int",)), True),
    ("st8", 89, 3, "int", "__t_st8",
     (("str",), ("int",), ("int",)), True),
    ("st16", 90, 3, "int", "__t_st16",
     (("str",), ("int",), ("int",)), True),
    ("st32", 91, 3, "int", "__t_st32",
     (("str",), ("int",), ("int",)), True),
    ("st64", 92, 3, "int", "__t_st64",
     (("str",), ("int",), ("int",)), True),
    ("memcpy", 93, 3, "int", "__t_memcpy",
     (("str",), ("str",), ("int",)), True),
    ("memset", 94, 3, "int", "__t_memset",
     (("str",), ("int",), ("int",)), True),
    # Machine builtins: raw instructions a kernel needs and a hosted program
    # cannot have.  They lower to `call __k_<name>`; Kernel/kruntime.s defines
    # the stub, so no hosted runtime body is emitted for them.
    ("peek8", 37, 1, "int", "__k_peek8", (("int",),), True),
    ("peek16", 38, 1, "int", "__k_peek16", (("int",),), True),
    ("peek32", 39, 1, "int", "__k_peek32", (("int",),), True),
    ("peek64", 40, 1, "int", "__k_peek64", (("int",),), True),
    ("poke8", 41, 2, "int", "__k_poke8", (("int",), ("int",)), True),
    ("poke16", 42, 2, "int", "__k_poke16", (("int",), ("int",)), True),
    ("poke32", 43, 2, "int", "__k_poke32", (("int",), ("int",)), True),
    ("poke64", 44, 2, "int", "__k_poke64", (("int",), ("int",)), True),
    ("outb", 45, 2, "int", "__k_outb", (("int",), ("int",)), True),
    ("inb", 46, 1, "int", "__k_inb", (("int",),), True),
    ("io_wait", 47, 0, "int", "__k_io_wait", (), True),
    ("hlt", 48, 0, "int", "__k_hlt", (), True),
    ("cli", 49, 0, "int", "__k_cli", (), True),
    ("sti", 50, 0, "int", "__k_sti", (), True),
    ("lgdt", 51, 1, "int", "__k_lgdt", (("int",),), True),
    ("lidt", 52, 1, "int", "__k_lidt", (("int",),), True),
    ("ltr", 53, 1, "int", "__k_ltr", (("int",),), True),
    ("invlpg", 54, 1, "int", "__k_invlpg", (("int",),), True),
    ("read_cr2", 55, 0, "int", "__k_read_cr2", (), True),
    ("read_cr3", 56, 0, "int", "__k_read_cr3", (), True),
    ("write_cr3", 57, 1, "int", "__k_write_cr3", (("int",),), True),
    ("rdtsc", 58, 0, "int", "__k_rdtsc", (), True),
    ("iretq", 59, 1, "int", "__k_iretq", (("int",),), True),
    # Framebuffer drawing: a kernel owns the screen, a hosted program owns a
    # terminal.  Coordinates are pixels, colors are VGA palette indices.
    ("fb_fill", 60, 5, "int", "__k_fb_fill",
     (("int",), ("int",), ("int",), ("int",), ("int",)), True),
    ("fb_text", 61, 4, "int", "__k_fb_text",
     (("int",), ("int",), ("int",), ("str",)), True),
    # The runtime owns the text console, so a window manager moves it through
    # these: place it at a pixel origin, or hide it while it is closed.
    ("console_place", 62, 2, "int", "__k_console_place",
     (("int",), ("int",)), True),
    ("console_hide", 63, 0, "int", "__k_console_hide", (), True),
    # Persistent storage: 512-byte sectors of the primary slave, which holds
    # the filesystem disk.  The kernel image lives on the master and is never
    # written, so a bad save can only damage data, not the running system.
    ("ata_read", 64, 3, "int", "__k_ata_read",
     (("int",), ("int",), ("int",)), True),
    ("ata_write", 65, 3, "int", "__k_ata_write",
     (("int",), ("int",), ("int",)), True),
    # One glyph at a pixel origin, for drawing text held in a buffer (the
    # editor and the file list) rather than in a string literal.
    ("fb_char", 66, 4, "int", "__k_fb_char",
     (("int",), ("int",), ("int",), ("int",)), True),
    # Compositing: draw into a back buffer, then copy a rectangle of it out.
    # A repaint that is painted straight to the screen shows its own erase.
    ("fb_back", 67, 0, "int", "__k_fb_back", (), True),
    ("fb_present", 68, 4, "int", "__k_fb_present",
     (("int",), ("int",), ("int",), ("int",)), True),
    # The runtime paints console cells as text arrives, but it cannot know what
    # covers them.  It reports the cells it touched so the window manager can
    # present them through the z-order: 0 for nothing, else 1 plus four bytes
    # of cell coordinates (x0, y0, x1, y1).
    ("console_dirty", 69, 0, "int", "__k_console_dirty", (), True),
    # Restrict the rectangles the runtime fills to a clip rectangle, so a band
    # repaint only costs the band.
    ("fb_clip", 70, 4, "int", "__k_fb_clip",
     (("int",), ("int",), ("int",), ("int",)), True),
    # Palette-indexed pixels at a whole-pixel scale, read straight out of a
    # buffer: one index byte per pixel and a fixed 16-colour palette in the
    # runtime.  Drawing an artwork into a buffer and blitting it are the whole
    # of the kernel's image support; there is no decoder.
    ("fb_indexed", 71, 6, "int", "__k_fb_indexed",
     (("int",), ("int",), ("int",), ("int",), ("int",), ("int",)), True),
)

# Builtins that only make sense in one of the two build modes.  Everything
# else works in both: ordinary code compiles unchanged for a kernel, and the
# kernel runtime in Kernel/kruntime.s supplies print, alloc and exit.
HOSTED_ONLY = frozenset({
    "input", "argv", "argc", "read_file", "file_size", "write_file",
    "append_file", "file_exists", "env", "sock", "fd_read", "fd_write", "fd_poll",
    "fd_pwrite", "fd_send", "shm", "arena_mark", "arena_release",
})
KERNEL_ONLY = frozenset({
    "peek8", "peek16", "peek32", "peek64",
    "poke8", "poke16", "poke32", "poke64",
    "outb", "inb", "io_wait", "hlt", "cli", "sti",
    "lgdt", "lidt", "ltr", "invlpg",
    "read_cr2", "read_cr3", "write_cr3", "rdtsc", "iretq",
    "fb_fill", "fb_text", "fb_char", "console_place", "console_hide",
    "ata_read", "ata_write", "fb_back", "fb_present", "console_dirty",
    "fb_clip", "fb_indexed",
})

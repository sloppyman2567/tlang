/* Freestanding tlang kernel image (K1).
 *
 * Kernel/mbr.s copies the flat image to 1 MiB and jumps to _boot32, which
 * zeroes .bss, builds the identity page tables and enters long mode.  The
 * image is one contiguous region so `objcopy -O binary` gives loadable bytes;
 * only .boot and .text/.data cost file space, since .bss is zeroed at boot.
 */
ENTRY(_boot32)
SECTIONS
{
  . = 1M;

  .boot : { *(.boot) }
  . = ALIGN(16);
  .text : { *(.text) }
  . = ALIGN(16);
  .data : { *(.data) }
  . = ALIGN(16);
  __bss_start = .;
  .bss  : { *(.bss) *(COMMON) }
  . = ALIGN(16);
  __bss_end = .;

  /DISCARD/ : { *(.note.gnu.property) *(.comment) }
}

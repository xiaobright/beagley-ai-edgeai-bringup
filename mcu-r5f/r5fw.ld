/* r5fw.ld - J722S MCU R5F0_0, everything in BTCM (32 KiB at R5F addr 0).
 *
 * The DT for 79000000.r5f sets ti,loczrama = 0, which makes the driver
 * place BTCM at R5F device address 0x0 (and ATCM at 0x41010000).  TISCI
 * boots the core at the ELF entry point, so 0x0 is where the vector
 * table has to be.
 */
ENTRY(_start)

MEMORY
{
	BTCM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x8000
}

SECTIONS
{
	.vectors : {
		KEEP(*(.vectors))
	} > BTCM

	.text : {
		*(.text*)
	} > BTCM

	.rodata : {
		*(.rodata*)
	} > BTCM

	/* Must be a real section in a LOAD segment: the TI vendor kernel
	 * bails out with -EINVAL from rproc_elf_load_rsc_table() otherwise. */
	.resource_table : {
		KEEP(*(.resource_table))
	} > BTCM

	.data : {
		*(.data*)
	} > BTCM

	.bss (NOLOAD) : {
		__bss_start = .;
		*(.bss*)
		*(COMMON)
		__bss_end = .;
	} > BTCM

	. = ALIGN(8);
	__stack_top = ORIGIN(BTCM) + LENGTH(BTCM);

	/DISCARD/ : {
		*(.ARM.exidx*)
		*(.ARM.extab*)
		*(.comment)
	}
}

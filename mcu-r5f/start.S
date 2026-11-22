/* start.S - minimal boot stub for J722S MCU R5F0_0
 *
 * The R5FSS is configured (via DT loczrama=0) with BTCM mapped at R5F
 * address 0x0, and TISCI boots the core at the ELF entry point.  So the
 * exception vector table must sit at address 0, and entry == reset vector.
 *
 * The core is released in ARM state (TEINIT cleared), caches off.
 */
	.syntax unified
	.arm

	.section .vectors, "ax"
	.global _start
_start:
	b	reset			/* 0x00  reset          */
	b	fault			/* 0x04  undefined      */
	b	fault			/* 0x08  svc            */
	b	fault			/* 0x0c  prefetch abort */
	b	fault			/* 0x10  data abort     */
	b	fault			/* 0x14  reserved       */
	b	fault			/* 0x18  irq            */
	b	fault			/* 0x1c  fiq            */

	.text
reset:
	ldr	sp, =__stack_top	/* stack grows down from top of BTCM */
	bl	main
fault:
	b	fault

/* r5fw.c - MCU R5F0_0 heartbeat / handshake demo, no TI SDK, freestanding.
 *
 * Shares one page of DDR with the A53 running Linux:
 *
 *   0xa1100000  word 0  MAGIC   R5F writes 0x0000C0DE once at startup
 *   0xa1100004  word 1  HEART   R5F increments forever
 *   0xa1100008  word 2  CMD     Linux writes, R5F reads
 *   0xa110000c  word 3  ECHO    R5F writes ~CMD  (bitwise NOT)
 *   0xa1100010  word 4  STAT    bit0 = alive
 *
 * 0xa1100000 is the `vision-apps-r5f-memory@a1100000` carveout that the
 * device tree hands to remoteproc2 (79000000.r5f) as its second
 * memory-region, so nothing else in Linux touches it.
 */

#include <stdint.h>

#define SHM_BASE   0xa1100000u

#define SHM_MAGIC  0u
#define SHM_HEART  1u
#define SHM_CMD    2u
#define SHM_ECHO   3u
#define SHM_STAT   4u

#define FW_MAGIC   0x0000C0DEu

/*
 * Mandatory on this kernel: rproc_elf_load_rsc_table() returns -EINVAL if the
 * ELF has no ".resource_table" section, and it fails silently (no dev_err).
 * A table with num = 0 registers no virtio/rpmsg devices, which is exactly
 * what we want for a standalone heartbeat firmware.
 */
struct resource_table {
	uint32_t ver;
	uint32_t num;
	uint32_t reserved[2];
} __attribute__((packed));

__attribute__((section(".resource_table"), used))
static const struct resource_table rsc_tbl = {
	.ver = 1,
	.num = 0,
	.reserved = { 0, 0 },
};

static volatile uint32_t *const shm = (volatile uint32_t *)SHM_BASE;

void main(void)
{
	uint32_t n = 0;

	shm[SHM_MAGIC] = FW_MAGIC;
	shm[SHM_HEART] = 0;
	shm[SHM_CMD]   = 0;
	shm[SHM_ECHO]  = 0;
	shm[SHM_STAT]  = 1;

	for (;;) {
		shm[SHM_HEART] = ++n;
		shm[SHM_ECHO]  = ~shm[SHM_CMD];

		/* delay loop so we don't saturate the DDR port; caches are off,
		 * so every store above is a real bus transaction */
		for (volatile uint32_t d = 0; d < 4000u; d++)
			__asm__ volatile ("nop");
	}
}

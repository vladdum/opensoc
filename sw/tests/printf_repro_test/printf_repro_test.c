// Reproducer for kronos #82 (dcache store-to-load on cacheable memory).
//
// The bug surfaced in kronos v0.6.2 (BRAM-backed dcache, stage6g/h) and was
// validated as fixed by stage6i. On the broken commit every digit position
// below collapsed to a NUL byte. Expected output (post-fix):
//
//   === printf_repro ===
//   [1] direct (no buf): 12345
//   [2] stack    buf[]:  12345
//   [3] bss      buf[]:  12345
//   [4] volatile buf[]:  12345
//   [5] one-byte probe:  A
//   === done ===

#include <stdint.h>

#define SIM_CTRL_BASE  0x40000000UL
#define SIM_CTRL_OUT   0x0
#define SIM_CTRL_CTRL  0x8
#define REG32(addr)    (*((volatile uint32_t *)(addr)))

static void sim_putchar(char c) {
  REG32(SIM_CTRL_BASE + SIM_CTRL_OUT) = (uint32_t)(unsigned char)c;
}

static void sim_puts(const char *s) {
  while (*s) sim_putchar(*s++);
}

static void sim_halt(uint32_t failures) {
  REG32(SIM_CTRL_BASE + SIM_CTRL_CTRL) = (failures << 1) | 1u;
  while (1) ;
}

static void putdec_direct(uint32_t v) {
  if (v == 0) { sim_putchar('0'); return; }
  if (v / 10) putdec_direct(v / 10);
  sim_putchar('0' + (v % 10));
}

static void putdec_stack(uint32_t v) {
  char buf[11];
  int pos = 0;
  if (v == 0) { sim_putchar('0'); return; }
  while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
  while (pos > 0) sim_putchar(buf[--pos]);
}

static char bss_buf[11];
static void putdec_bss(uint32_t v) {
  int pos = 0;
  if (v == 0) { sim_putchar('0'); return; }
  while (v > 0) { bss_buf[pos++] = '0' + (v % 10); v /= 10; }
  while (pos > 0) sim_putchar(bss_buf[--pos]);
}

static void putdec_volatile(uint32_t v) {
  volatile char buf[11];
  int pos = 0;
  if (v == 0) { sim_putchar('0'); return; }
  while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
  while (pos > 0) sim_putchar(buf[--pos]);
}

int main(void) {
  sim_puts("=== printf_repro ===\n");

  sim_puts("[1] direct (no buf): ");
  putdec_direct(12345);
  sim_putchar('\n');

  sim_puts("[2] stack    buf[]:  ");
  putdec_stack(12345);
  sim_putchar('\n');

  sim_puts("[3] bss      buf[]:  ");
  putdec_bss(12345);
  sim_putchar('\n');

  sim_puts("[4] volatile buf[]:  ");
  putdec_volatile(12345);
  sim_putchar('\n');

  {
    char one;
    one = 'A';
    sim_puts("[5] one-byte probe:  ");
    sim_putchar(one);
    sim_putchar('\n');
  }

  sim_puts("=== done ===\n");
  sim_halt(0);
  return 0;
}

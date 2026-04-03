// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

// ---------------------------------------------------------------------------
// Memory-mapped register access
// ---------------------------------------------------------------------------

#define SIM_CTRL_BASE  0x40000000UL
#define SIM_CTRL_OUT   0x0
#define SIM_CTRL_CTRL  0x8

#define TIMER_BASE     0x40010000UL
#define TIMER_MTIME    0x0
#define TIMER_MTIMEH   0x4

#define REG32(addr) (*((volatile uint32_t *)(addr)))

// ---------------------------------------------------------------------------
// Output helpers (direct SimCtrl writes — no ibex common dependency)
// ---------------------------------------------------------------------------

static void sim_putchar(char c) {
  REG32(SIM_CTRL_BASE + SIM_CTRL_OUT) = (uint32_t)(unsigned char)c;
}

static void sim_puts(const char *s) {
  while (*s) sim_putchar(*s++);
}

static void sim_puthex(uint32_t v) {
  for (int i = 28; i >= 0; i -= 4) {
    int d = (v >> i) & 0xf;
    sim_putchar(d < 10 ? '0' + d : 'a' + d - 10);
  }
}

// ---------------------------------------------------------------------------
// Timer helpers (polled — no interrupt setup needed)
// ---------------------------------------------------------------------------

static uint64_t get_mtime(void) {
  uint32_t hi, lo;
  // Read hi twice to guard against mid-read rollover
  do {
    hi = REG32(TIMER_BASE + TIMER_MTIMEH);
    lo = REG32(TIMER_BASE + TIMER_MTIME);
  } while (REG32(TIMER_BASE + TIMER_MTIMEH) != hi);
  return ((uint64_t)hi << 32) | lo;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(void) {
  sim_puts("Hello OpenSoC!\n");
  sim_puthex(0xDEADBEEF);
  sim_putchar('\n');
  sim_puthex(0xBAADF00D);
  sim_putchar('\n');

  // Polled timer: print Tick!/Tock! five times, 2000-cycle intervals
  uint64_t next = get_mtime() + 2000;
  int ticks = 0;
  while (ticks < 5) {
    if (get_mtime() >= next) {
      ticks++;
      next += 2000;
      sim_puts(ticks & 1 ? "Tick!\n" : "Tock!\n");
    }
  }

  return 0;
}

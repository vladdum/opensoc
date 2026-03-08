// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// SoC0: Sends a message over UART TX, then spins (lets SoC1 halt sim).

#include "simple_system_common.h"

#define UART_BASE    0x40000
#define UART_THR     0x00
#define UART_LSR     0x04
#define UART_DIV     0x0C

#define UART_LSR_TX_READY  (1 << 0)

static void uart_init(uint32_t divisor) {
  DEV_WRITE(UART_BASE + UART_DIV, divisor);
}

static void uart_putc_hw(char c) {
  while (!(DEV_READ(UART_BASE + UART_LSR, 0) & UART_LSR_TX_READY))
    ;
  DEV_WRITE(UART_BASE + UART_THR, (uint32_t)c);
}

static void uart_puts_hw(const char *s) {
  while (*s) {
    uart_putc_hw(*s++);
  }
}

int main(int argc, char **argv) {
  puts("SoC0: UART send starting\n");

  uart_init(16);
  uart_puts_hw("Hello from SoC0\n");

  puts("SoC0: Send complete\n");

  // Do NOT return — returning triggers sim_halt via crt0.
  // Spin here and let SoC1 (receiver) halt the simulation.
  while (1) {
    asm volatile("wfi");
  }
}

// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// SoC1: Receives a message over UART RX, echoes via SimCtrl, then halts.

#include "simple_system_common.h"

#define UART_BASE    0x40000
#define UART_RBR     0x00
#define UART_LSR     0x04
#define UART_DIV     0x0C

#define UART_LSR_RX_READY  (1 << 1)

static void uart_init(uint32_t divisor) {
  DEV_WRITE(UART_BASE + UART_DIV, divisor);
}

static int uart_getc_hw(void) {
  while (!(DEV_READ(UART_BASE + UART_LSR, 0) & UART_LSR_RX_READY))
    ;
  return DEV_READ(UART_BASE + UART_RBR, 0) & 0xFF;
}

int main(int argc, char **argv) {
  puts("SoC1: UART recv starting\n");

  uart_init(16);

  // Receive characters until newline
  while (1) {
    int c = uart_getc_hw();
    putchar(c);
    if (c == '\n') {
      break;
    }
  }

  puts("SoC1: Receive complete\n");

  // Return from main — crt0 will call sim_halt()
  return 0;
}

// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "simple_system_common.h"
#include "opensoc_regs.h"

static void uart_init(uint32_t divisor) {
  DEV_WRITE(UART_DIV, divisor);
}

static void uart_putc(char c) {
  // Poll until TX FIFO has space
  while (!(DEV_READ(UART_LSR, 0) & UART_LSR_TX_READY))
    ;
  DEV_WRITE(UART_THR, (uint32_t)c);
}

static void uart_puts(const char *s) {
  while (*s) {
    uart_putc(*s++);
  }
}

int main(int argc, char **argv) {
  puts("UART test starting\n");

  // Set baud divisor (arbitrary value for simulation)
  uart_init(16);

  // Transmit a test string via UART TX
  uart_puts("Hello UART\n");

  puts("UART test done\n");
  return 0;
}

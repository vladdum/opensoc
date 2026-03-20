// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "simple_system_common.h"
#include "opensoc_regs.h"

static void i2c_wait_idle(void) {
  while (DEV_READ(I2C_STATUS, 0) & I2C_STATUS_BUSY)
    ;
}

int main(int argc, char **argv) {
  puts("I2C test starting\n");

  // Set prescaler (arbitrary value for simulation)
  DEV_WRITE(I2C_PRESCALE, 8);

  // Send a write transaction: START + address byte + data byte + STOP
  // Address byte: 0x50 << 1 | 0 (write) = 0xA0
  DEV_WRITE(I2C_TX_DATA, 0xA0);
  DEV_WRITE(I2C_CTRL, I2C_CTRL_START);
  i2c_wait_idle();

  uint32_t status = DEV_READ(I2C_STATUS, 0);
  puts("I2C status after addr: ");
  puthex(status);
  putchar('\n');

  // Send data byte with STOP
  DEV_WRITE(I2C_TX_DATA, 0x42);
  DEV_WRITE(I2C_CTRL, I2C_CTRL_STOP);
  i2c_wait_idle();

  status = DEV_READ(I2C_STATUS, 0);
  puts("I2C status after data: ");
  puthex(status);
  putchar('\n');

  puts("I2C test done\n");
  return 0;
}

// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "simple_system_common.h"
#include "opensoc_regs.h"

int main(int argc, char **argv) {
  puts("GPIO test starting\n");

  // Set all pins as output
  DEV_WRITE(GPIO_DIR, 0xFFFFFFFF);

  // Write a pattern
  DEV_WRITE(GPIO_OUT, 0xA5A5A5A5);

  // Read back the output register
  uint32_t out_val = DEV_READ(GPIO_OUT, 0);
  puts("GPIO OUT: ");
  puthex(out_val);
  putchar('\n');

  if (out_val == 0xA5A5A5A5) {
    puts("GPIO test PASSED\n");
  } else {
    puts("GPIO test FAILED\n");
  }

  // Read input register (in simulation, gpio_i is tied to 0)
  uint32_t in_val = DEV_READ(GPIO_IN, 0);
  puts("GPIO IN:  ");
  puthex(in_val);
  putchar('\n');

  return 0;
}

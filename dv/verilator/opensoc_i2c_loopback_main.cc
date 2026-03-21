// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "opensoc_i2c_loopback_sim.h"

int main(int argc, char **argv) {
  I2cLoopbackSim sim("TOP.opensoc_i2c_loopback.u_soc.u_ram.u_ram",
                      I2cLoopbackSim::kRAM_SizeBytes / 4);

  return sim.Main(argc, argv);
}

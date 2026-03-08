// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "opensoc_dual_uart_sim.h"

int main(int argc, char **argv) {
  OpenSocDualUartSim sim(
      "TOP.opensoc_dual_uart.u_soc0.u_ram.u_ram",
      "TOP.opensoc_dual_uart.u_soc1.u_ram.u_ram",
      OpenSocDualUartSim::kRAM_SizeBytes / 4);

  return sim.Main(argc, argv);
}

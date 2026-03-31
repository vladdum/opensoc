// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "opensoc_top_sim.h"

int main(int argc, char **argv) {
  OpenSocSim sim("TOP.opensoc_top_wrapper.u_opensoc_top.u_ram.u_ram",
                 OpenSocSim::kRAM_SizeBytes / 4);

  return sim.Main(argc, argv);
}

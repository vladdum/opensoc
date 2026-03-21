// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <fstream>
#include <iostream>

#include "Vopensoc_i2c_loopback__Syms.h"
#include "opensoc_i2c_loopback_sim.h"
#include "verilated_toplevel.h"
#include "verilator_memutil.h"
#include "verilator_sim_ctrl.h"

I2cLoopbackSim::I2cLoopbackSim(const char *ram_hier_path, int ram_size_words)
    : _ram(ram_hier_path, ram_size_words, 4) {}

int I2cLoopbackSim::Main(int argc, char **argv) {
  bool exit_app;
  int ret_code = Setup(argc, argv, exit_app);

  if (exit_app) {
    return ret_code;
  }

  Run();

  if (!Finish()) {
    return 1;
  }

  return 0;
}

int I2cLoopbackSim::Setup(int argc, char **argv, bool &exit_app) {
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();

  simctrl.SetTop(&_top, &_top.IO_CLK, &_top.IO_RST_N,
                 VerilatorSimCtrlFlags::ResetPolarityNegative);

  _memutil.RegisterMemoryArea("ram", kRAM_BaseAddr, &_ram);
  simctrl.RegisterExtension(&_memutil);

  exit_app = false;
  return simctrl.ParseCommandArgs(argc, argv, exit_app);
}

void I2cLoopbackSim::Run() {
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();

  std::cout << "Simulation of OpenSoC I2C Loopback" << std::endl
            << "===================================" << std::endl
            << std::endl;

  simctrl.RunSimulation();
}

bool I2cLoopbackSim::Finish() {
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();

  if (!simctrl.WasSimulationSuccessful()) {
    return false;
  }

  // Skip pcounts (DPI scope ambiguity with wrapper module)
  return true;
}

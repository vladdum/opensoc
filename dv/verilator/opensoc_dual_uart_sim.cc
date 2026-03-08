// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "opensoc_dual_uart_sim.h"
#include "verilated_toplevel.h"
#include "verilator_memutil.h"
#include "verilator_sim_ctrl.h"

OpenSocDualUartSim::OpenSocDualUartSim(const char *ram0_hier_path,
                                       const char *ram1_hier_path,
                                       int ram_size_words)
    : _ram0(ram0_hier_path, ram_size_words, 4),
      _ram1(ram1_hier_path, ram_size_words, 4) {}

int OpenSocDualUartSim::Main(int argc, char **argv) {
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

int OpenSocDualUartSim::Setup(int argc, char **argv, bool &exit_app) {
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();

  simctrl.SetTop(&_top, &_top.IO_CLK, &_top.IO_RST_N,
                 VerilatorSimCtrlFlags::ResetPolarityNegative);

  // Register ram0 with the extension (handles --meminit=ram0,<file>)
  _memutil0.RegisterMemoryArea("ram0", kRAM_BaseAddr, &_ram0);
  simctrl.RegisterExtension(&_memutil0);

  // Register ram1 separately (NOT as extension — same base address would
  // conflict if both were in one DpiMemUtil, but separate instances are fine)
  _memutil1.RegisterMemoryArea("ram1", kRAM_BaseAddr, &_ram1);

  // Scan argv for --meminit=ram1,<file> before passing to simctrl.
  // Extract and remove it so simctrl doesn't see an unknown memory name.
  std::string ram1_file;
  std::vector<char *> filtered_argv;

  for (int i = 0; i < argc; i++) {
    std::string arg(argv[i]);
    // Match both --meminit=ram1,FILE and -l ram1,FILE short forms
    if (arg.rfind("--meminit=ram1,", 0) == 0) {
      ram1_file = arg.substr(strlen("--meminit=ram1,"));
    } else if (arg.rfind("-l", 0) == 0 && arg == "-l" && i + 1 < argc) {
      std::string next(argv[i + 1]);
      if (next.rfind("ram1,", 0) == 0) {
        ram1_file = next.substr(strlen("ram1,"));
        i++;  // skip next arg
      } else {
        filtered_argv.push_back(argv[i]);
      }
    } else {
      filtered_argv.push_back(argv[i]);
    }
  }

  int filtered_argc = static_cast<int>(filtered_argv.size());
  exit_app = false;
  int ret = simctrl.ParseCommandArgs(filtered_argc, filtered_argv.data(),
                                     exit_app);

  if (exit_app) {
    return ret;
  }

  // Load ram1 file if provided
  if (!ram1_file.empty()) {
    MemImageType type = DpiMemUtil::GetMemImageType(ram1_file, nullptr);
    _memutil1.GetUnderlying()->LoadFileToNamedMem(true, "ram1", ram1_file,
                                                  type);
  }

  return ret;
}

void OpenSocDualUartSim::Run() {
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();

  std::cout << "Simulation of OpenSoC Dual UART" << std::endl
            << "===============================" << std::endl
            << std::endl;

  simctrl.RunSimulation();
}

bool OpenSocDualUartSim::Finish() {
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();

  if (!simctrl.WasSimulationSuccessful()) {
    return false;
  }

  // Skip performance counter printing — DPI export scope ambiguity
  // with two opensoc_top instances.

  return true;
}

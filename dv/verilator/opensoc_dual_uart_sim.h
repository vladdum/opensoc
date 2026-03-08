// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "verilated_toplevel.h"
#include "verilator_memutil.h"

class OpenSocDualUartSim {
 public:
  static constexpr uint32_t kRAM_BaseAddr = 0x100000u;
  static constexpr uint32_t kRAM_SizeBytes = 0x100000u;

  OpenSocDualUartSim(const char *ram0_hier_path, const char *ram1_hier_path,
                     int ram_size_words);
  virtual ~OpenSocDualUartSim() {}
  virtual int Main(int argc, char **argv);

 protected:
  opensoc_dual_uart _top;
  VerilatorMemUtil _memutil0;  // Registered as extension (handles --meminit=ram0,...)
  VerilatorMemUtil _memutil1;  // NOT registered; ram1 loaded manually
  MemArea _ram0;
  MemArea _ram1;

  virtual int Setup(int argc, char **argv, bool &exit_app);
  virtual void Run();
  virtual bool Finish();
};

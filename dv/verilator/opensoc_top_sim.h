// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "verilated_toplevel.h"
#include "verilator_memutil.h"

class OpenSocSim {
 public:
  static constexpr uint32_t kRAM_BaseAddr = 0x20000000u;
  static constexpr uint32_t kRAM_SizeBytes = 0x100000u;

  OpenSocSim(const char *ram_hier_path, int ram_size_words);
  virtual ~OpenSocSim() {}
  virtual int Main(int argc, char **argv);

 protected:
  opensoc_top_wrapper _top;
  VerilatorMemUtil _memutil;
  MemArea _ram;

  virtual int Setup(int argc, char **argv, bool &exit_app);
  virtual void Run();
  virtual bool Finish();
};

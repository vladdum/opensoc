// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// OpenSoC unified configuration package.
//
// Used for both ASIC synthesis and full-feature FPGA targets (e.g. Arty A7-100T).
// Edit this file to change the default parameter values.

package opensoc_config_pkg;
  import axi_pkg::*;

  // -------------------------------------------------------------------------
  // Memory
  // -------------------------------------------------------------------------
  localparam              SRAMInitFile     = "";
`ifdef FPGA_XILINX
  localparam int unsigned RamDepth         = 131072;  // 512 KB
`elsif SYNTHESIS
  localparam int unsigned RamDepth         = 16384;   //  64 KB
`else
  localparam int unsigned RamDepth         = 131072;  // 512 KB (sim)
`endif

  // -------------------------------------------------------------------------
  // Accelerator / IP enables
  // Defaults: all off. FPGA/ASIC targets pass explicit +define+ to enable.
  // -------------------------------------------------------------------------
`ifndef EnableReLU
  `define EnableReLU    1'b0
`endif
`ifndef EnableVMAC
  `define EnableVMAC    1'b0
`endif
`ifndef EnableSgDma
  `define EnableSgDma   1'b0
`endif
`ifndef EnableSoftmax
  `define EnableSoftmax 1'b0
`endif
`ifndef EnableCrypto
  `define EnableCrypto  1'b0
`endif
`ifndef EnableConv1d
  `define EnableConv1d  1'b0
`endif
`ifndef EnableConv2d
  `define EnableConv2d  1'b0
`endif
`ifndef EnableGemm
  `define EnableGemm    1'b0
`endif
  localparam bit EnableReLU    = `EnableReLU;
  localparam bit EnableVMAC    = `EnableVMAC;
  localparam bit EnableSgDma   = `EnableSgDma;
  localparam bit EnableSoftmax = `EnableSoftmax;
  localparam bit EnableCrypto  = `EnableCrypto;
  localparam bit EnableConv1d  = `EnableConv1d;
  localparam bit EnableConv2d  = `EnableConv2d;
  localparam bit EnableGemm    = `EnableGemm;

  // -------------------------------------------------------------------------
  // AXI crossbar latency mode
  // CUT_ALL_PORTS inserts pipeline registers on all crossbar ports for timing
  // closure.  This works on both FPGA and ASIC (adds minor area overhead).
  // -------------------------------------------------------------------------
  localparam xbar_latency_e XbarLatencyMode = CUT_ALL_PORTS;

endpackage

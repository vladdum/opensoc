// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// OpenSoC unified configuration package.
//
// Used for both ASIC synthesis and full-feature FPGA targets (e.g. Arty A7-100T).
// Edit this file to change the default parameter values.
//
// VCS does not support overriding enum parameters via command line.  FuseSoC
// sets these via +define+NAME=VALUE (vlogdefine).  The `ifndef guards let the
// command-line define win; if nothing is set the defaults below are used.

`ifndef USE_KRONOS
`ifndef RV32M
  `define RV32M ibex_pkg::RV32MFast
`endif
`ifndef RV32B
  `define RV32B ibex_pkg::RV32BNone
`endif
`ifndef RV32ZC
  `define RV32ZC ibex_pkg::RV32ZcaZcbZcmp
`endif
`ifndef RegFile
  `define RegFile ibex_pkg::RegFileFF
`endif
`endif  // USE_KRONOS

package opensoc_config_pkg;
`ifndef USE_KRONOS
  import ibex_pkg::*;
`endif
  import axi_pkg::*;

`ifndef USE_KRONOS
  // -------------------------------------------------------------------------
  // Ibex CPU
  // -------------------------------------------------------------------------
  localparam bit          SecureIbex       = 1'b0;
  localparam int unsigned LockstepOffset   = 1;
  localparam bit          ICacheScramble   = 1'b0;
  localparam bit          PMPEnable        = 1'b0;
  localparam int unsigned PMPGranularity   = 0;
  localparam int unsigned PMPNumRegions    = 4;
  localparam int unsigned MHPMCounterNum   = 0;
  localparam int unsigned MHPMCounterWidth = 40;
  localparam bit          RV32E            = 1'b0;
  localparam rv32m_e      RV32M            = `RV32M;
  localparam rv32b_e      RV32B            = `RV32B;
  localparam rv32zc_e     RV32ZC           = `RV32ZC;
  localparam regfile_e    RegFile          = `RegFile;
  localparam bit          BranchTargetALU  = 1'b0;
  localparam bit          WritebackStage   = 1'b0;
  localparam bit          ICache           = 1'b0;
  localparam bit          DbgTriggerEn     = 1'b0;
  localparam bit          ICacheECC        = 1'b0;
  localparam bit          BranchPredictor  = 1'b0;
`endif  // USE_KRONOS

  // -------------------------------------------------------------------------
  // Memory
  // -------------------------------------------------------------------------
  localparam              SRAMInitFile     = "";
  // RamDepth is flow-specific:
  //   FPGA (Vivado):    131072 × 32 = 512 KB (fits XC7A100T 607 KB BRAM)
  //   ASIC (Sky130):     16384 × 32 =  64 KB (sky130_sram_1rw_32x16384 stub)
  //   Simulation:       131072 × 32 = 512 KB
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

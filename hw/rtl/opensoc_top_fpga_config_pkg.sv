// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// OpenSoC FPGA (Digilent Basys 3 / Xilinx Artix-7 XC7A35T) configuration
// package.  Edit this file to change the default parameter values for the
// Vivado FPGA synthesis flow.

package opensoc_top_fpga_config_pkg;
  import ibex_pkg::*;
  import axi_pkg::*;

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
  localparam rv32m_e      RV32M            = RV32MFast;
  localparam rv32b_e      RV32B            = RV32BNone;
  localparam rv32zc_e     RV32ZC           = RV32ZcaZcbZcmp;
  localparam regfile_e    RegFile          = RegFileFPGA;  // block RAM register file
  localparam bit          BranchTargetALU  = 1'b0;
  localparam bit          WritebackStage   = 1'b0;
  localparam bit          ICache           = 1'b0;
  localparam bit          DbgTriggerEn     = 1'b0;
  localparam bit          ICacheECC        = 1'b0;
  localparam bit          BranchPredictor  = 1'b0;

  // -------------------------------------------------------------------------
  // Memory (64 KB block RAM — Basys 3 XC7A35T resource limit)
  // -------------------------------------------------------------------------
  localparam              SRAMInitFile     = "";
  localparam int unsigned RamDepth         = 16384;  // 64 KB (16384 × 32-bit words)

  // -------------------------------------------------------------------------
  // Accelerator enables (all off to fit XC7A35T)
  // -------------------------------------------------------------------------
  localparam bit EnableReLU    = 1'b0;
  localparam bit EnableVMAC    = 1'b0;
  localparam bit EnableSgDma   = 1'b0;
  localparam bit EnableSoftmax = 1'b0;

  // -------------------------------------------------------------------------
  // AXI crossbar latency mode (pipeline stages for timing closure)
  // -------------------------------------------------------------------------
  localparam xbar_latency_e XbarLatencyMode = CUT_ALL_PORTS;

endpackage

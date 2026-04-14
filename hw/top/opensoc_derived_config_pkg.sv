// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// OpenSoC derived configuration package.
//
// Computes every derived value (crossbar dimensions, port indices, AXI
// widths, typedefs, crossbar config struct, and address map) from the
// parameters in opensoc_config_pkg.
//
// opensoc_top and any other modules that need design-wide constants should
// import this package rather than the individual config packages.

`include "axi/typedef.svh"

package opensoc_derived_config_pkg;
  import axi_pkg::*;

  // =========================================================================
  // Configurable parameters — forwarded from the config package.
  // =========================================================================
  localparam              SRAMInitFile     = opensoc_config_pkg::SRAMInitFile;
  localparam int unsigned   RamDepth         = opensoc_config_pkg::RamDepth;
  localparam bit            EnableReLU       = opensoc_config_pkg::EnableReLU;
  localparam bit            EnableVMAC       = opensoc_config_pkg::EnableVMAC;
  localparam bit            EnableSgDma      = opensoc_config_pkg::EnableSgDma;
  localparam bit            EnableSoftmax    = opensoc_config_pkg::EnableSoftmax;
  localparam bit            EnableCrypto     = opensoc_config_pkg::EnableCrypto;
  localparam bit            EnableConv1d     = opensoc_config_pkg::EnableConv1d;
  localparam bit            EnableConv2d     = opensoc_config_pkg::EnableConv2d;
  localparam bit            EnableGemm       = opensoc_config_pkg::EnableGemm;
  localparam xbar_latency_e XbarLatencyMode  = opensoc_config_pkg::XbarLatencyMode;

  // =========================================================================
  // Derived parameters — computed from the config values above
  // =========================================================================

  // -------------------------------------------------------------------------
  // Crossbar dimensions (computed from accelerator enables)
  // -------------------------------------------------------------------------
  localparam int unsigned NumAccel   = 32'(EnableReLU) + 32'(EnableVMAC)
                                     + 32'(EnableSgDma) + 32'(EnableSoftmax)
                                     + 32'(EnableConv1d) + 32'(EnableConv2d)
                                     + 32'(EnableGemm);
  localparam int unsigned NumMasters = 3 + NumAccel;  // instr + data + PIO DMA + accel DMAs
  // RAM + SimCtrl + Timer + UART + PIO + I2C + [Crypto] + accel ctrls
  localparam int unsigned NumSlaves  = 6 + 32'(EnableCrypto) + NumAccel;
  localparam int unsigned NumRules   = NumSlaves;

  // -------------------------------------------------------------------------
  // Master port indices: 0=instr, 1=data, [accel DMAs...], PIO DMA (last)
  // -------------------------------------------------------------------------
  localparam int unsigned PioDmaMstIdx   = NumMasters - 1;
  localparam int unsigned ReluDmaMstIdx  = 2;
  localparam int unsigned VmacDmaMstIdx  = 2 + 32'(EnableReLU);
  localparam int unsigned SgDmaDmaMstIdx = 2 + 32'(EnableReLU) + 32'(EnableVMAC);
  localparam int unsigned SmaxDmaMstIdx    = 2 + 32'(EnableReLU) + 32'(EnableVMAC) + 32'(EnableSgDma);
  localparam int unsigned Conv1dDmaMstIdx  = 2 + 32'(EnableReLU) + 32'(EnableVMAC)
                                           + 32'(EnableSgDma) + 32'(EnableSoftmax);
  localparam int unsigned Conv2dDmaMstIdx  = 2 + 32'(EnableReLU) + 32'(EnableVMAC)
                                           + 32'(EnableSgDma) + 32'(EnableSoftmax)
                                           + 32'(EnableConv1d);
  localparam int unsigned GemmDmaMstIdx   = 2 + 32'(EnableReLU) + 32'(EnableVMAC)
                                           + 32'(EnableSgDma) + 32'(EnableSoftmax)
                                           + 32'(EnableConv1d) + 32'(EnableConv2d);

  // -------------------------------------------------------------------------
  // Slave port indices: 0=RAM, 1=SimCtrl, 2=Timer, 3=UART, 4=PIO, 5=I2C,
  //                     [6=Crypto if enabled], [accel ctrls...]
  // -------------------------------------------------------------------------
  localparam int unsigned CryptoSlvIdx = 6;  // valid only when EnableCrypto=1
  localparam int unsigned ReluSlvIdx   = 6 + 32'(EnableCrypto);
  localparam int unsigned VmacSlvIdx   = 6 + 32'(EnableCrypto) + 32'(EnableReLU);
  localparam int unsigned SgDmaSlvIdx  = 6 + 32'(EnableCrypto) + 32'(EnableReLU) + 32'(EnableVMAC);
  localparam int unsigned SmaxSlvIdx    = 6 + 32'(EnableCrypto) + 32'(EnableReLU)
                                        + 32'(EnableVMAC) + 32'(EnableSgDma);
  localparam int unsigned Conv1dSlvIdx  = 6 + 32'(EnableCrypto) + 32'(EnableReLU)
                                        + 32'(EnableVMAC) + 32'(EnableSgDma) + 32'(EnableSoftmax);
  localparam int unsigned Conv2dSlvIdx     = 6 + 32'(EnableCrypto) + 32'(EnableReLU)
                                           + 32'(EnableVMAC) + 32'(EnableSgDma)
                                           + 32'(EnableSoftmax) + 32'(EnableConv1d);
  localparam int unsigned GemmSlvIdx      = 6 + 32'(EnableCrypto) + 32'(EnableReLU)
                                           + 32'(EnableVMAC) + 32'(EnableSgDma)
                                           + 32'(EnableSoftmax) + 32'(EnableConv1d)
                                           + 32'(EnableConv2d);

  // -------------------------------------------------------------------------
  // AXI bus widths
  // -------------------------------------------------------------------------
  localparam int unsigned AxiAddrWidth  = 32;
  localparam int unsigned AxiDataWidth  = 32;
  localparam int unsigned AxiStrbWidth  = AxiDataWidth / 8;
  localparam int unsigned AxiIdWidthIn  = 1;    // ID width at xbar slave ports (master side)
  localparam int unsigned AxiIdWidthOut = AxiIdWidthIn + $clog2(NumMasters);  // xbar prepends routing bits
  localparam int unsigned AxiUserWidth  = 1;

  // -------------------------------------------------------------------------
  // AXI type definitions
  // -------------------------------------------------------------------------
  typedef logic [AxiAddrWidth-1:0]  axi_addr_t;
  typedef logic [AxiDataWidth-1:0]  axi_data_t;
  typedef logic [AxiStrbWidth-1:0]  axi_strb_t;
  typedef logic [AxiIdWidthIn-1:0]  axi_id_in_t;
  typedef logic [AxiIdWidthOut-1:0] axi_id_out_t;
  typedef logic [AxiUserWidth-1:0]  axi_user_t;

  // Slave-port types (master-facing, narrow ID)
  `AXI_TYPEDEF_ALL(axi_in,  axi_addr_t, axi_id_in_t,  axi_data_t, axi_strb_t, axi_user_t)
  // Master-port types (slave-facing, wide ID)
  `AXI_TYPEDEF_ALL(axi_out, axi_addr_t, axi_id_out_t, axi_data_t, axi_strb_t, axi_user_t)

  // -------------------------------------------------------------------------
  // AXI crossbar configuration struct
  // -------------------------------------------------------------------------
  localparam xbar_cfg_t XbarCfg = '{
    NoSlvPorts:         NumMasters,
    NoMstPorts:         NumSlaves,
    MaxMstTrans:        4,
    MaxSlvTrans:        4,
    FallThrough:        1'b0,
    LatencyMode:        XbarLatencyMode,
    PipelineStages:     32'd0,
    AxiIdWidthSlvPorts: AxiIdWidthIn,
    AxiIdUsedSlvPorts:  AxiIdWidthIn,
    UniqueIds:          1'b0,
    AxiAddrWidth:       AxiAddrWidth,
    AxiDataWidth:       AxiDataWidth,
    NoAddrRules:        NumRules
  };

  // -------------------------------------------------------------------------
  // Address map
  // -------------------------------------------------------------------------
  typedef xbar_rule_32_t [NumRules-1:0] addr_map_t;

  function automatic addr_map_t compute_addr_map();
    addr_map_t   map;
    int unsigned r;
    // Core slaves (always present)
    map[0] = '{ idx: 32'd0, start_addr: 32'h2000_0000, end_addr: 32'h2010_0000 }; // RAM      1 MB
    map[1] = '{ idx: 32'd1, start_addr: 32'h4000_0000, end_addr: 32'h4000_0400 }; // SimCtrl  1 kB
    map[2] = '{ idx: 32'd2, start_addr: 32'h4001_0000, end_addr: 32'h4001_0400 }; // Timer    1 kB
    map[3] = '{ idx: 32'd3, start_addr: 32'h4002_0000, end_addr: 32'h4002_0400 }; // UART     1 kB
    map[4] = '{ idx: 32'd4, start_addr: 32'h4003_0000, end_addr: 32'h4003_0400 }; // PIO      1 kB
    map[5] = '{ idx: 32'd5, start_addr: 32'h4004_0000, end_addr: 32'h4004_0400 }; // I2C      1 kB
    // Optional slaves
    r = 6;
    if (EnableCrypto)  begin map[r] = '{ idx: r, start_addr: 32'h4010_0000, end_addr: 32'h4010_1000 }; r = r + 1; end
    if (EnableReLU)    begin map[r] = '{ idx: r, start_addr: 32'h4005_0000, end_addr: 32'h4005_0400 }; r = r + 1; end
    if (EnableVMAC)    begin map[r] = '{ idx: r, start_addr: 32'h4006_0000, end_addr: 32'h4006_0400 }; r = r + 1; end
    if (EnableSgDma)   begin map[r] = '{ idx: r, start_addr: 32'h4007_0000, end_addr: 32'h4007_0400 }; r = r + 1; end
    if (EnableSoftmax) begin map[r] = '{ idx: r, start_addr: 32'h4008_0000, end_addr: 32'h4008_0400 }; r = r + 1; end
    if (EnableConv1d)  begin map[r] = '{ idx: r, start_addr: 32'h4009_0000, end_addr: 32'h4009_0400 }; r = r + 1; end
    if (EnableConv2d)  begin map[r] = '{ idx: r, start_addr: 32'h400A_0000, end_addr: 32'h400A_0400 }; r = r + 1; end
    if (EnableGemm)    begin map[r] = '{ idx: r, start_addr: 32'h400B_0000, end_addr: 32'h400B_0400 }; r = r + 1; end
    return map;
  endfunction

  localparam addr_map_t AddrMap = compute_addr_map();

endpackage

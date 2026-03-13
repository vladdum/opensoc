// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Based on ibex_simple_system from the Ibex project.
// Copyright lowRISC contributors.

// VCS does not support overriding enum and string parameters via command line. Instead, a `define
// is used that can be set from the command line. If no value has been specified, this gives a
// default. Other simulators don't take the detour via `define and can override the corresponding
// parameters directly.
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

`ifndef INSTR_CYCLE_DELAY
  `define INSTR_CYCLE_DELAY 0
`endif

`include "axi/typedef.svh"

/**
 * OpenSoC Top-Level
 *
 * This is a basic system consisting of an ibex, a 1 MB sram for instruction/data
 * and a small memory mapped control module for outputting ASCII text and
 * controlling/halting the simulation from the software running on the ibex.
 *
 * It is designed to be used with verilator but should work with other
 * simulators, a small amount of work may be required to support the
 * simulator_ctrl module.
 *
 * The interconnect uses a PULP AXI4 crossbar (axi_xbar) with three master ports
 * (instruction fetch, data, and ReLU DMA) bridged via axi_from_mem, and seven
 * slave ports (RAM, SimCtrl, Timer, UART, GPIO, I2C, ReLU ctrl) bridged via
 * axi_to_mem.
 */

module opensoc_top (
  input  IO_CLK,
  input  IO_RST_N,

  // UART
  output uart_tx_o,
  input  uart_rx_i,

  // GPIO
  input  [31:0] gpio_i,
  output [31:0] gpio_o,
  output [31:0] gpio_oe,

  // I2C (open-drain modeled as separate signals)
  output i2c_scl_o,
  output i2c_scl_oe,
  input  i2c_scl_i,
  output i2c_sda_o,
  output i2c_sda_oe,
  input  i2c_sda_i
);

  parameter bit                 SecureIbex               = 1'b0;
  parameter int unsigned        LockstepOffset           = 1;
  parameter bit                 ICacheScramble           = 1'b0;
  parameter bit                 PMPEnable                = 1'b0;
  parameter int unsigned        PMPGranularity           = 0;
  parameter int unsigned        PMPNumRegions            = 4;
  parameter int unsigned        MHPMCounterNum           = 0;
  parameter int unsigned        MHPMCounterWidth         = 40;
  parameter bit                 RV32E                    = 1'b0;
  parameter ibex_pkg::rv32m_e   RV32M                    = `RV32M;
  parameter ibex_pkg::rv32b_e   RV32B                    = `RV32B;
  parameter ibex_pkg::rv32zc_e  RV32ZC                   = `RV32ZC;
  parameter ibex_pkg::regfile_e RegFile                  = `RegFile;
  parameter bit                 BranchTargetALU          = 1'b0;
  parameter bit                 WritebackStage           = 1'b0;
  parameter bit                 ICache                   = 1'b0;
  parameter bit                 DbgTriggerEn             = 1'b0;
  parameter bit                 ICacheECC                = 1'b0;
  parameter bit                 BranchPredictor          = 1'b0;
  parameter                     SRAMInitFile             = "";

  logic clk_sys = 1'b0, rst_sys_n;

  // interrupts
  logic timer_irq;
  logic uart_irq;
  logic gpio_irq;
  logic i2c_irq;
  logic relu_irq;

  // -------------------------------------------------------------------------
  // AXI type parameters
  // -------------------------------------------------------------------------
  localparam int unsigned AxiAddrWidth  = 32;
  localparam int unsigned AxiDataWidth  = 32;
  localparam int unsigned AxiStrbWidth  = AxiDataWidth / 8;
  localparam int unsigned AxiIdWidthIn  = 1;   // ID width at xbar slave ports (master side)
  localparam int unsigned AxiIdWidthOut = AxiIdWidthIn + $clog2(NumMasters); // xbar prepends bits for NumMasters slave ports
  localparam int unsigned AxiUserWidth  = 1;

  // AXI type definitions — slave-port side (master-facing, narrow ID)
  typedef logic [AxiAddrWidth-1:0]  axi_addr_t;
  typedef logic [AxiDataWidth-1:0]  axi_data_t;
  typedef logic [AxiStrbWidth-1:0]  axi_strb_t;
  typedef logic [AxiIdWidthIn-1:0]  axi_id_in_t;
  typedef logic [AxiIdWidthOut-1:0] axi_id_out_t;
  typedef logic [AxiUserWidth-1:0]  axi_user_t;

  // Slave-port types (master-facing, narrow ID)
  `AXI_TYPEDEF_ALL(axi_in, axi_addr_t, axi_id_in_t, axi_data_t, axi_strb_t, axi_user_t)

  // Master-port types (slave-facing, wide ID)
  `AXI_TYPEDEF_ALL(axi_out, axi_addr_t, axi_id_out_t, axi_data_t, axi_strb_t, axi_user_t)

  // -------------------------------------------------------------------------
  // Crossbar configuration
  // -------------------------------------------------------------------------
  localparam int unsigned NumMasters = 3; // instr + data + ReLU DMA (xbar "slave ports")
  localparam int unsigned NumSlaves  = 7; // RAM, SimCtrl, Timer, UART, GPIO, I2C, ReLU ctrl (xbar "master ports")
  localparam int unsigned NumRules   = 7;

  localparam axi_pkg::xbar_cfg_t XbarCfg = '{
    NoSlvPorts:         NumMasters,
    NoMstPorts:         NumSlaves,
    MaxMstTrans:        4,
    MaxSlvTrans:        4,
    FallThrough:        1'b0,
    LatencyMode:        axi_pkg::NO_LATENCY,
    PipelineStages:     0,
    AxiIdWidthSlvPorts: AxiIdWidthIn,
    AxiIdUsedSlvPorts:  AxiIdWidthIn,
    UniqueIds:          1'b0,
    AxiAddrWidth:       AxiAddrWidth,
    AxiDataWidth:       AxiDataWidth,
    NoAddrRules:        NumRules
  };

  // Address map
  localparam axi_pkg::xbar_rule_32_t [NumRules-1:0] AddrMap = '{
    '{ idx: 32'd0, start_addr: 32'h0010_0000, end_addr: 32'h0020_0000 }, // RAM     1 MB
    '{ idx: 32'd1, start_addr: 32'h0002_0000, end_addr: 32'h0002_0400 }, // SimCtrl 1 kB
    '{ idx: 32'd2, start_addr: 32'h0003_0000, end_addr: 32'h0003_0400 }, // Timer   1 kB
    '{ idx: 32'd3, start_addr: 32'h0004_0000, end_addr: 32'h0004_0400 }, // UART    1 kB
    '{ idx: 32'd4, start_addr: 32'h0005_0000, end_addr: 32'h0005_0400 }, // GPIO    1 kB
    '{ idx: 32'd5, start_addr: 32'h0006_0000, end_addr: 32'h0006_0400 }, // I2C     1 kB
    '{ idx: 32'd6, start_addr: 32'h0007_0000, end_addr: 32'h0007_0400 }  // ReLU    1 kB
  };

  // -------------------------------------------------------------------------
  // Ibex instruction-fetch signals
  // -------------------------------------------------------------------------
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic        instr_err;

  // -------------------------------------------------------------------------
  // Ibex data-port signals
  // -------------------------------------------------------------------------
  logic        data_req;
  logic        data_gnt;
  logic        data_rvalid;
  logic        data_we;
  logic [ 3:0] data_be;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic [31:0] data_rdata;
  logic        data_err;

  // ECC integrity signals
  logic [6:0] data_rdata_intg;
  logic [6:0] instr_rdata_intg;

  // -------------------------------------------------------------------------
  // AXI signal bundles
  // -------------------------------------------------------------------------
  // From axi_from_mem bridges (xbar slave-port side)
  axi_in_req_t  [NumMasters-1:0] xbar_slv_req;
  axi_in_resp_t [NumMasters-1:0] xbar_slv_resp;

  // To axi_to_mem bridges (xbar master-port side)
  axi_out_req_t  [NumSlaves-1:0] xbar_mst_req;
  axi_out_resp_t [NumSlaves-1:0] xbar_mst_resp;

  // -------------------------------------------------------------------------
  // Peripheral memory-interface signals (from axi_to_mem)
  // -------------------------------------------------------------------------
  logic        mem_req   [NumSlaves];
  logic        mem_gnt   [NumSlaves];
  logic [31:0] mem_addr  [NumSlaves];
  logic [31:0] mem_wdata [NumSlaves];
  logic [ 3:0] mem_strb  [NumSlaves];
  logic        mem_we    [NumSlaves];
  logic        mem_rvalid[NumSlaves];
  logic [31:0] mem_rdata [NumSlaves];

  // -------------------------------------------------------------------------
  // Clock and reset
  // -------------------------------------------------------------------------
  `ifdef VERILATOR
    assign clk_sys = IO_CLK;
    assign rst_sys_n = IO_RST_N;
  `else
    initial begin
      rst_sys_n = 1'b0;
      #8
      rst_sys_n = 1'b1;
    end
    always begin
      #1 clk_sys = 1'b0;
      #1 clk_sys = 1'b1;
    end
  `endif

  // -------------------------------------------------------------------------
  // ECC integrity (SecureIbex only)
  // -------------------------------------------------------------------------
  if (SecureIbex) begin : g_mem_rdata_ecc
    logic [31:0] unused_data_rdata;
    logic [31:0] unused_instr_rdata;

    prim_secded_inv_39_32_enc u_data_rdata_intg_gen (
      .data_i (data_rdata),
      .data_o ({data_rdata_intg, unused_data_rdata})
    );

    prim_secded_inv_39_32_enc u_instr_rdata_intg_gen (
      .data_i (instr_rdata),
      .data_o ({instr_rdata_intg, unused_instr_rdata})
    );
  end else begin : g_no_mem_rdata_ecc
    assign data_rdata_intg = '0;
    assign instr_rdata_intg = '0;
  end

  // -------------------------------------------------------------------------
  // Ibex CPU
  // -------------------------------------------------------------------------
  ibex_top_tracing #(
      .SecureIbex      ( SecureIbex       ),
      .LockstepOffset  ( LockstepOffset   ),
      .ICacheScramble  ( ICacheScramble   ),
      .PMPEnable       ( PMPEnable        ),
      .PMPGranularity  ( PMPGranularity   ),
      .PMPNumRegions   ( PMPNumRegions    ),
      .MHPMCounterNum  ( MHPMCounterNum   ),
      .MHPMCounterWidth( MHPMCounterWidth ),
      .RV32E           ( RV32E            ),
      .RV32M           ( RV32M            ),
      .RV32B           ( RV32B            ),
      .RV32ZC          ( RV32ZC           ),
      .RegFile         ( RegFile          ),
      .BranchTargetALU ( BranchTargetALU  ),
      .ICache          ( ICache           ),
      .ICacheECC       ( ICacheECC        ),
      .WritebackStage  ( WritebackStage   ),
      .BranchPredictor ( BranchPredictor  ),
      .DbgTriggerEn    ( DbgTriggerEn     ),
      .DmBaseAddr      ( 32'h00100000     ),
      .DmAddrMask      ( 32'h00000003     ),
      .DmHaltAddr      ( 32'h00100000     ),
      .DmExceptionAddr ( 32'h00100000     )
    ) u_top (
      .clk_i                     (clk_sys),
      .rst_ni                    (rst_sys_n),

      .test_en_i                 (1'b0),
      .scan_rst_ni               (1'b1),
      .ram_cfg_icache_tag_i      (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),
      .ram_cfg_rsp_icache_tag_o  (),
      .ram_cfg_icache_data_i     (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),
      .ram_cfg_rsp_icache_data_o (),

      .hart_id_i                 (32'b0),
      // First instruction executed is at 0x0 + 0x80
      .boot_addr_i               (32'h00100000),

      .instr_req_o               (instr_req),
      .instr_gnt_i               (instr_gnt),
      .instr_rvalid_i            (instr_rvalid),
      .instr_addr_o              (instr_addr),
      .instr_rdata_i             (instr_rdata),
      .instr_rdata_intg_i        (instr_rdata_intg),
      .instr_err_i               (instr_err),

      .data_req_o                (data_req),
      .data_gnt_i                (data_gnt),
      .data_rvalid_i             (data_rvalid),
      .data_we_o                 (data_we),
      .data_be_o                 (data_be),
      .data_addr_o               (data_addr),
      .data_wdata_o              (data_wdata),
      .data_wdata_intg_o         (),
      .data_rdata_i              (data_rdata),
      .data_rdata_intg_i         (data_rdata_intg),
      .data_err_i                (data_err),

      .irq_software_i            (1'b0),
      .irq_timer_i               (timer_irq),
      .irq_external_i            (1'b0),
      .irq_fast_i                ({11'b0, relu_irq, i2c_irq, gpio_irq, uart_irq}),
      .irq_nm_i                  (1'b0),

      .scramble_key_valid_i      ('0),
      .scramble_key_i            ('0),
      .scramble_nonce_i          ('0),
      .scramble_req_o            (),

      .debug_req_i               (1'b0),
      .crash_dump_o              (),
      .double_fault_seen_o       (),

      .fetch_enable_i            (ibex_pkg::IbexMuBiOn),
      .alert_minor_o             (),
      .alert_major_internal_o    (),
      .alert_major_bus_o         (),
      .core_sleep_o              (),

      .lockstep_cmp_en_o         (),

      .data_req_shadow_o         (),
      .data_we_shadow_o          (),
      .data_be_shadow_o          (),
      .data_addr_shadow_o        (),
      .data_wdata_shadow_o       (),
      .data_wdata_intg_shadow_o  (),

      .instr_req_shadow_o        (),
      .instr_addr_shadow_o       ()
    );

  // -------------------------------------------------------------------------
  // AXI bridges: Ibex memory ports → AXI (axi_from_mem)
  // -------------------------------------------------------------------------

  // Instruction port (read-only)
  axi_from_mem #(
    .MemAddrWidth ( 32              ),
    .AxiAddrWidth ( AxiAddrWidth    ),
    .DataWidth    ( AxiDataWidth    ),
    .MaxRequests  ( 2               ),
    .AxiProt      ( 3'b000          ),
    .axi_req_t    ( axi_in_req_t    ),
    .axi_rsp_t    ( axi_in_resp_t   )
  ) u_axi_from_mem_instr (
    .clk_i           (clk_sys),
    .rst_ni          (rst_sys_n),
    .mem_req_i       (instr_req),
    .mem_addr_i      (instr_addr),
    .mem_we_i        (1'b0),
    .mem_wdata_i     (32'b0),
    .mem_be_i        (4'b1111),
    .mem_gnt_o       (instr_gnt),
    .mem_rsp_valid_o (instr_rvalid),
    .mem_rsp_rdata_o (instr_rdata),
    .mem_rsp_error_o (instr_err),
    .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .axi_req_o       (xbar_slv_req[0]),
    .axi_rsp_i       (xbar_slv_resp[0])
  );

  // Data port (read/write)
  axi_from_mem #(
    .MemAddrWidth ( 32              ),
    .AxiAddrWidth ( AxiAddrWidth    ),
    .DataWidth    ( AxiDataWidth    ),
    .MaxRequests  ( 2               ),
    .AxiProt      ( 3'b000          ),
    .axi_req_t    ( axi_in_req_t    ),
    .axi_rsp_t    ( axi_in_resp_t   )
  ) u_axi_from_mem_data (
    .clk_i           (clk_sys),
    .rst_ni          (rst_sys_n),
    .mem_req_i       (data_req),
    .mem_addr_i      (data_addr),
    .mem_we_i        (data_we),
    .mem_wdata_i     (data_wdata),
    .mem_be_i        (data_be),
    .mem_gnt_o       (data_gnt),
    .mem_rsp_valid_o (data_rvalid),
    .mem_rsp_rdata_o (data_rdata),
    .mem_rsp_error_o (data_err),
    .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .axi_req_o       (xbar_slv_req[1]),
    .axi_rsp_i       (xbar_slv_resp[1])
  );

  // -------------------------------------------------------------------------
  // ReLU DMA signals (between relu_accel and axi_from_mem)
  // -------------------------------------------------------------------------
  logic        relu_dma_req;
  logic [31:0] relu_dma_addr;
  logic        relu_dma_we;
  logic [31:0] relu_dma_wdata;
  logic [3:0]  relu_dma_be;
  logic        relu_dma_gnt;
  logic        relu_dma_rvalid;
  logic [31:0] relu_dma_rdata;
  logic        relu_dma_err;

  // ReLU DMA port
  axi_from_mem #(
    .MemAddrWidth ( 32              ),
    .AxiAddrWidth ( AxiAddrWidth    ),
    .DataWidth    ( AxiDataWidth    ),
    .MaxRequests  ( 2               ),
    .AxiProt      ( 3'b000          ),
    .axi_req_t    ( axi_in_req_t    ),
    .axi_rsp_t    ( axi_in_resp_t   )
  ) u_axi_from_mem_relu_dma (
    .clk_i           (clk_sys),
    .rst_ni          (rst_sys_n),
    .mem_req_i       (relu_dma_req),
    .mem_addr_i      (relu_dma_addr),
    .mem_we_i        (relu_dma_we),
    .mem_wdata_i     (relu_dma_wdata),
    .mem_be_i        (relu_dma_be),
    .mem_gnt_o       (relu_dma_gnt),
    .mem_rsp_valid_o (relu_dma_rvalid),
    .mem_rsp_rdata_o (relu_dma_rdata),
    .mem_rsp_error_o (relu_dma_err),
    .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .axi_req_o       (xbar_slv_req[2]),
    .axi_rsp_i       (xbar_slv_resp[2])
  );

  // -------------------------------------------------------------------------
  // AXI crossbar
  // -------------------------------------------------------------------------
  axi_xbar #(
    .Cfg           ( XbarCfg               ),
    .ATOPs         ( 1'b0                  ),
    .Connectivity  ( '1                    ),
    .slv_aw_chan_t ( axi_in_aw_chan_t      ),
    .mst_aw_chan_t ( axi_out_aw_chan_t     ),
    .w_chan_t      ( axi_in_w_chan_t       ),
    .slv_b_chan_t  ( axi_in_b_chan_t       ),
    .mst_b_chan_t  ( axi_out_b_chan_t      ),
    .slv_ar_chan_t ( axi_in_ar_chan_t      ),
    .mst_ar_chan_t ( axi_out_ar_chan_t     ),
    .slv_r_chan_t  ( axi_in_r_chan_t       ),
    .mst_r_chan_t  ( axi_out_r_chan_t      ),
    .slv_req_t     ( axi_in_req_t          ),
    .slv_resp_t    ( axi_in_resp_t         ),
    .mst_req_t     ( axi_out_req_t         ),
    .mst_resp_t    ( axi_out_resp_t        ),
    .rule_t        ( axi_pkg::xbar_rule_32_t )
  ) u_axi_xbar (
    .clk_i                  (clk_sys),
    .rst_ni                 (rst_sys_n),
    .test_i                 (1'b0),
    .slv_ports_req_i        (xbar_slv_req),
    .slv_ports_resp_o       (xbar_slv_resp),
    .mst_ports_req_o        (xbar_mst_req),
    .mst_ports_resp_i       (xbar_mst_resp),
    .addr_map_i             (AddrMap),
    .en_default_mst_port_i  ('0),
    .default_mst_port_i     ('0)
  );

  // -------------------------------------------------------------------------
  // AXI bridges: AXI → memory-mapped peripherals (axi_to_mem)
  // -------------------------------------------------------------------------
  // Unused signals from axi_to_mem
  logic [NumSlaves-1:0] axi_to_mem_busy;
  axi_pkg::atop_t       mem_atop [NumSlaves];

  for (genvar i = 0; i < NumSlaves; i++) begin : gen_axi_to_mem
    axi_to_mem #(
      .axi_req_t  ( axi_out_req_t  ),
      .axi_resp_t ( axi_out_resp_t ),
      .AddrWidth  ( AxiAddrWidth   ),
      .DataWidth  ( AxiDataWidth   ),
      .IdWidth    ( AxiIdWidthOut  ),
      .NumBanks   ( 1              ),
      .BufDepth   ( 1              )
    ) u_axi_to_mem (
      .clk_i       (clk_sys),
      .rst_ni      (rst_sys_n),
      .busy_o      (axi_to_mem_busy[i]),
      .axi_req_i   (xbar_mst_req[i]),
      .axi_resp_o  (xbar_mst_resp[i]),
      .mem_req_o   (mem_req[i]),
      .mem_gnt_i   (mem_gnt[i]),
      .mem_addr_o  (mem_addr[i]),
      .mem_wdata_o (mem_wdata[i]),
      .mem_strb_o  (mem_strb[i]),
      .mem_atop_o  (mem_atop[i]),
      .mem_we_o    (mem_we[i]),
      .mem_rvalid_i(mem_rvalid[i]),
      .mem_rdata_i (mem_rdata[i])
    );
  end

  // All peripherals grant immediately (single-cycle grant)
  assign mem_gnt[0] = mem_req[0]; // RAM
  assign mem_gnt[1] = mem_req[1]; // SimCtrl
  assign mem_gnt[2] = mem_req[2]; // Timer
  assign mem_gnt[3] = mem_req[3]; // UART
  assign mem_gnt[4] = mem_req[4]; // GPIO
  assign mem_gnt[5] = mem_req[5]; // I2C
  assign mem_gnt[6] = mem_req[6]; // ReLU

  // -------------------------------------------------------------------------
  // SRAM (single-port, crossbar arbitrates instr vs data)
  // -------------------------------------------------------------------------
  ram_1p #(
      .Depth(1024*1024/4),
      .MemInitFile(SRAMInitFile)
    ) u_ram (
      .clk_i       (clk_sys),
      .rst_ni      (rst_sys_n),

      .req_i       (mem_req[0]),
      .we_i        (mem_we[0]),
      .be_i        (mem_strb[0]),
      .addr_i      (mem_addr[0]),
      .wdata_i     (mem_wdata[0]),
      .rvalid_o    (mem_rvalid[0]),
      .rdata_o     (mem_rdata[0])
    );

  // -------------------------------------------------------------------------
  // Simulator control
  // -------------------------------------------------------------------------
  simulator_ctrl #(
    .LogName("opensoc_top.log")
    ) u_simulator_ctrl (
      .clk_i     (clk_sys),
      .rst_ni    (rst_sys_n),

      .req_i     (mem_req[1]),
      .we_i      (mem_we[1]),
      .be_i      (mem_strb[1]),
      .addr_i    (mem_addr[1]),
      .wdata_i   (mem_wdata[1]),
      .rvalid_o  (mem_rvalid[1]),
      .rdata_o   (mem_rdata[1])
    );

  // -------------------------------------------------------------------------
  // Timer
  // -------------------------------------------------------------------------
  logic timer_err_unused;

  timer #(
    .DataWidth    (32),
    .AddressWidth (32)
    ) u_timer (
      .clk_i          (clk_sys),
      .rst_ni         (rst_sys_n),

      .timer_req_i    (mem_req[2]),
      .timer_we_i     (mem_we[2]),
      .timer_be_i     (mem_strb[2]),
      .timer_addr_i   (mem_addr[2]),
      .timer_wdata_i  (mem_wdata[2]),
      .timer_rvalid_o (mem_rvalid[2]),
      .timer_rdata_o  (mem_rdata[2]),
      .timer_err_o    (timer_err_unused),
      .timer_intr_o   (timer_irq)
    );

  // -------------------------------------------------------------------------
  // UART
  // -------------------------------------------------------------------------
  uart u_uart (
    .clk_i     (clk_sys),
    .rst_ni    (rst_sys_n),

    .req_i     (mem_req[3]),
    .addr_i    (mem_addr[3]),
    .we_i      (mem_we[3]),
    .be_i      (mem_strb[3]),
    .wdata_i   (mem_wdata[3]),
    .rvalid_o  (mem_rvalid[3]),
    .rdata_o   (mem_rdata[3]),

    .irq_o     (uart_irq),

    .uart_tx_o (uart_tx_o),
    .uart_rx_i (uart_rx_i)
  );

  // -------------------------------------------------------------------------
  // GPIO
  // -------------------------------------------------------------------------
  gpio u_gpio (
    .clk_i     (clk_sys),
    .rst_ni    (rst_sys_n),

    .req_i     (mem_req[4]),
    .addr_i    (mem_addr[4]),
    .we_i      (mem_we[4]),
    .be_i      (mem_strb[4]),
    .wdata_i   (mem_wdata[4]),
    .rvalid_o  (mem_rvalid[4]),
    .rdata_o   (mem_rdata[4]),

    .irq_o     (gpio_irq),

    .gpio_i    (gpio_i),
    .gpio_o    (gpio_o),
    .gpio_oe   (gpio_oe)
  );

  // -------------------------------------------------------------------------
  // I2C Controller
  // -------------------------------------------------------------------------
  i2c_controller u_i2c (
    .clk_i      (clk_sys),
    .rst_ni     (rst_sys_n),

    .req_i      (mem_req[5]),
    .addr_i     (mem_addr[5]),
    .we_i       (mem_we[5]),
    .be_i       (mem_strb[5]),
    .wdata_i    (mem_wdata[5]),
    .rvalid_o   (mem_rvalid[5]),
    .rdata_o    (mem_rdata[5]),

    .irq_o      (i2c_irq),

    .i2c_scl_o  (i2c_scl_o),
    .i2c_scl_oe (i2c_scl_oe),
    .i2c_scl_i  (i2c_scl_i),
    .i2c_sda_o  (i2c_sda_o),
    .i2c_sda_oe (i2c_sda_oe),
    .i2c_sda_i  (i2c_sda_i)
  );

  // -------------------------------------------------------------------------
  // ReLU Accelerator
  // -------------------------------------------------------------------------
  relu_accel u_relu_accel (
    .clk_i          (clk_sys),
    .rst_ni         (rst_sys_n),

    .ctrl_req_i     (mem_req[6]),
    .ctrl_addr_i    (mem_addr[6]),
    .ctrl_we_i      (mem_we[6]),
    .ctrl_be_i      (mem_strb[6]),
    .ctrl_wdata_i   (mem_wdata[6]),
    .ctrl_rvalid_o  (mem_rvalid[6]),
    .ctrl_rdata_o   (mem_rdata[6]),

    .dma_req_o      (relu_dma_req),
    .dma_addr_o     (relu_dma_addr),
    .dma_we_o       (relu_dma_we),
    .dma_wdata_o    (relu_dma_wdata),
    .dma_be_o       (relu_dma_be),
    .dma_gnt_i      (relu_dma_gnt),
    .dma_rvalid_i   (relu_dma_rvalid),
    .dma_rdata_i    (relu_dma_rdata),
    .dma_err_i      (relu_dma_err),

    .irq_o          (relu_irq)
  );

  export "DPI-C" function mhpmcounter_num;

  function automatic int unsigned mhpmcounter_num();
    return u_top.u_ibex_top.u_ibex_core.cs_registers_i.MHPMCounterNum;
  endfunction

  export "DPI-C" function mhpmcounter_get;

  function automatic longint unsigned mhpmcounter_get(int index);
    return u_top.u_ibex_top.u_ibex_core.cs_registers_i.mhpmcounter[index];
  endfunction

endmodule

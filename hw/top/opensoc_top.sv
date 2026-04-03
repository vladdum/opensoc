// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Based on ibex_simple_system from the Ibex project.
// Copyright lowRISC contributors.

`ifndef INSTR_CYCLE_DELAY
  `define INSTR_CYCLE_DELAY 0
`endif

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
 * The interconnect uses a PULP AXI4 crossbar (axi_xbar) with seven master ports
 * (instruction fetch, data, ReLU DMA, VMAC DMA, SG DMA, Softmax DMA, PIO DMA)
 * bridged via axi_from_mem, and ten slave ports (RAM, SimCtrl, Timer, UART, PIO,
 * I2C, ReLU, VMAC, SG DMA, Softmax) bridged via axi_to_mem.
 */

module opensoc_top
  import axi_pkg::*;
  import opensoc_derived_config_pkg::*;
(
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

  logic clk_sys, rst_sys_n;

  // interrupts
  logic timer_irq;
  logic uart_irq;
  logic pio_irq;
  logic i2c_irq;
  logic relu_irq;
  logic vmac_irq;
  logic sg_dma_irq;
  logic softmax_irq;
  logic conv1d_irq;
  logic [14:0] ibex_irq_fast;

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
  assign clk_sys   = IO_CLK;
  assign rst_sys_n = IO_RST_N;

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
  // RVFI signals: declared here so opensoc_top_sim can connect ibex_tracer via
  // hierarchical reference without polluting the module's port list.
`ifdef RVFI
  logic        rvfi_valid;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn;
  logic        rvfi_trap;
  logic        rvfi_halt;
  logic        rvfi_intr;
  logic [ 1:0] rvfi_mode;
  logic [ 1:0] rvfi_ixl;
  logic [ 4:0] rvfi_rs1_addr;
  logic [ 4:0] rvfi_rs2_addr;
  logic [ 4:0] rvfi_rs3_addr;
  logic [31:0] rvfi_rs1_rdata;
  logic [31:0] rvfi_rs2_rdata;
  logic [31:0] rvfi_rs3_rdata;
  logic [ 4:0] rvfi_rd_addr;
  logic [31:0] rvfi_rd_wdata;
  logic [31:0] rvfi_pc_rdata;
  logic [31:0] rvfi_pc_wdata;
  logic [31:0] rvfi_mem_addr;
  logic [ 3:0] rvfi_mem_rmask;
  logic [ 3:0] rvfi_mem_wmask;
  logic [31:0] rvfi_mem_rdata;
  logic [31:0] rvfi_mem_wdata;
  logic        rvfi_ext_expanded_insn_valid;
  logic [15:0] rvfi_ext_expanded_insn;
`endif

  ibex_top #(
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
      .boot_addr_i               (32'h20000000),

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
      .irq_fast_i                (ibex_irq_fast),
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

`ifdef RVFI
     ,.rvfi_valid                (rvfi_valid                ),
      .rvfi_order                (rvfi_order                ),
      .rvfi_insn                 (rvfi_insn                 ),
      .rvfi_trap                 (rvfi_trap                 ),
      .rvfi_halt                 (rvfi_halt                 ),
      .rvfi_intr                 (rvfi_intr                 ),
      .rvfi_mode                 (rvfi_mode                 ),
      .rvfi_ixl                  (rvfi_ixl                  ),
      .rvfi_rs1_addr             (rvfi_rs1_addr             ),
      .rvfi_rs2_addr             (rvfi_rs2_addr             ),
      .rvfi_rs3_addr             (rvfi_rs3_addr             ),
      .rvfi_rs1_rdata            (rvfi_rs1_rdata            ),
      .rvfi_rs2_rdata            (rvfi_rs2_rdata            ),
      .rvfi_rs3_rdata            (rvfi_rs3_rdata            ),
      .rvfi_rd_addr              (rvfi_rd_addr              ),
      .rvfi_rd_wdata             (rvfi_rd_wdata             ),
      .rvfi_pc_rdata             (rvfi_pc_rdata             ),
      .rvfi_pc_wdata             (rvfi_pc_wdata             ),
      .rvfi_mem_addr             (rvfi_mem_addr             ),
      .rvfi_mem_rmask            (rvfi_mem_rmask            ),
      .rvfi_mem_wmask            (rvfi_mem_wmask            ),
      .rvfi_mem_rdata            (rvfi_mem_rdata            ),
      .rvfi_mem_wdata            (rvfi_mem_wdata            ),
      .rvfi_ext_pre_mip          (),
      .rvfi_ext_post_mip         (),
      .rvfi_ext_nmi              (),
      .rvfi_ext_nmi_int          (),
      .rvfi_ext_debug_req        (),
      .rvfi_ext_debug_mode       (),
      .rvfi_ext_rf_wr_suppress   (),
      .rvfi_ext_mcycle           (),
      .rvfi_ext_mhpmcounters     (),
      .rvfi_ext_mhpmcountersh    (),
      .rvfi_ext_ic_scr_key_valid (),
      .rvfi_ext_irq_valid        (),
      .rvfi_ext_expanded_insn_valid(rvfi_ext_expanded_insn_valid),
      .rvfi_ext_expanded_insn    (rvfi_ext_expanded_insn    ),
      .rvfi_ext_expanded_insn_last()
`endif
    );

    assign ibex_irq_fast = {7'b0, conv1d_irq, softmax_irq, sg_dma_irq, vmac_irq, relu_irq, i2c_irq, pio_irq, uart_irq};

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
    .clk_i           (clk_sys                  ),
    .rst_ni          (rst_sys_n                ),
    .mem_req_i       (instr_req                ),
    .mem_addr_i      (instr_addr               ),
    .mem_we_i        (1'b0                     ),
    .mem_wdata_i     (32'b0                    ),
    .mem_be_i        (4'b1111                  ),
    .mem_gnt_o       (instr_gnt                ),
    .mem_rsp_valid_o (instr_rvalid             ),
    .mem_rsp_rdata_o (instr_rdata              ),
    .mem_rsp_error_o (instr_err                ),
    .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .axi_req_o       (xbar_slv_req[0]          ),
    .axi_rsp_i       (xbar_slv_resp[0]         )
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
    .clk_i           (clk_sys                  ),
    .rst_ni          (rst_sys_n                ),
    .mem_req_i       (data_req                 ),
    .mem_addr_i      (data_addr                ),
    .mem_we_i        (data_we                  ),
    .mem_wdata_i     (data_wdata               ),
    .mem_be_i        (data_be                  ),
    .mem_gnt_o       (data_gnt                 ),
    .mem_rsp_valid_o (data_rvalid              ),
    .mem_rsp_rdata_o (data_rdata               ),
    .mem_rsp_error_o (data_err                 ),
    .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE),
    .axi_req_o       (xbar_slv_req[1]          ),
    .axi_rsp_i       (xbar_slv_resp[1]         )
  );

  // -------------------------------------------------------------------------
  // PIO DMA signals (between pio and axi_from_mem)
  // -------------------------------------------------------------------------
  logic        pio_dma_req;
  logic [31:0] pio_dma_addr;
  logic        pio_dma_we;
  logic [31:0] pio_dma_wdata;
  logic [3:0]  pio_dma_be;
  logic        pio_dma_gnt;
  logic        pio_dma_rvalid;
  logic [31:0] pio_dma_rdata;
  logic        pio_dma_err;

  // PIO DMA port
  axi_from_mem #(
    .MemAddrWidth ( 32              ),
    .AxiAddrWidth ( AxiAddrWidth    ),
    .DataWidth    ( AxiDataWidth    ),
    .MaxRequests  ( 2               ),
    .AxiProt      ( 3'b000          ),
    .axi_req_t    ( axi_in_req_t    ),
    .axi_rsp_t    ( axi_in_resp_t   )
  ) u_axi_from_mem_pio_dma (
    .clk_i           (clk_sys                    ),
    .rst_ni          (rst_sys_n                  ),
    .mem_req_i       (pio_dma_req                ),
    .mem_addr_i      (pio_dma_addr               ),
    .mem_we_i        (pio_dma_we                 ),
    .mem_wdata_i     (pio_dma_wdata              ),
    .mem_be_i        (pio_dma_be                 ),
    .mem_gnt_o       (pio_dma_gnt                ),
    .mem_rsp_valid_o (pio_dma_rvalid             ),
    .mem_rsp_rdata_o (pio_dma_rdata              ),
    .mem_rsp_error_o (pio_dma_err                ),
    .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE  ),
    .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE  ),
    .axi_req_o       (xbar_slv_req[PioDmaMstIdx] ),
    .axi_rsp_i       (xbar_slv_resp[PioDmaMstIdx])
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
    .rule_t        ( xbar_rule_32_t )
  ) u_axi_xbar (
    .clk_i                  (clk_sys      ),
    .rst_ni                 (rst_sys_n    ),
    .test_i                 (1'b0         ),
    .slv_ports_req_i        (xbar_slv_req ),
    .slv_ports_resp_o       (xbar_slv_resp),
    .mst_ports_req_o        (xbar_mst_req ),
    .mst_ports_resp_i       (xbar_mst_resp),
    .addr_map_i             (AddrMap      ),
    .en_default_mst_port_i  ('0           ),
    .default_mst_port_i     ('0           )
  );

  // -------------------------------------------------------------------------
  // AXI bridges: AXI → memory-mapped peripherals (axi_to_mem)
  // -------------------------------------------------------------------------
  // Output-only ports from axi_to_mem that are not consumed by this design
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NumSlaves-1:0] axi_to_mem_busy;
  axi_pkg::atop_t       mem_atop [NumSlaves];
  /* verilator lint_on UNUSEDSIGNAL */

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
      .clk_i       (clk_sys           ),
      .rst_ni      (rst_sys_n         ),
      .busy_o      (axi_to_mem_busy[i]),
      .axi_req_i   (xbar_mst_req[i]   ),
      .axi_resp_o  (xbar_mst_resp[i]  ),
      .mem_req_o   (mem_req[i]        ),
      .mem_gnt_i   (mem_gnt[i]        ),
      .mem_addr_o  (mem_addr[i]       ),
      .mem_wdata_o (mem_wdata[i]      ),
      .mem_strb_o  (mem_strb[i]       ),
      .mem_atop_o  (mem_atop[i]       ),
      .mem_we_o    (mem_we[i]         ),
      .mem_rvalid_i(mem_rvalid[i]     ),
      .mem_rdata_i (mem_rdata[i]      )
    );
  end

  // All peripherals grant immediately (single-cycle grant)
  for (genvar g = 0; g < NumSlaves; g++) begin : gen_mem_gnt
    assign mem_gnt[g] = mem_req[g];
  end

  // -------------------------------------------------------------------------
  // SRAM (single-port, crossbar arbitrates instr vs data)
  // -------------------------------------------------------------------------
  opensoc_ram #(
      .Depth(RamDepth),
      .MemInitFile(SRAMInitFile)
    ) u_ram (
      .clk_i       (clk_sys      ),
      .rst_ni      (rst_sys_n    ),

      .req_i       (mem_req[0]   ),
      .we_i        (mem_we[0]    ),
      .be_i        (mem_strb[0]  ),
      .addr_i      (mem_addr[0]  ),
      .wdata_i     (mem_wdata[0] ),
      .rvalid_o    (mem_rvalid[0]),
      .rdata_o     (mem_rdata[0] )
    );

  // -------------------------------------------------------------------------
  // Simulator control (sim-only: uses $fopen/$fwrite/$finish)
  // For synthesis, provide a minimal stub that ACKs requests and returns 0.
  // -------------------------------------------------------------------------
`ifdef SYNTHESIS
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      mem_rvalid[1] <= 1'b0;
    end else begin
      mem_rvalid[1] <= mem_req[1];
    end
  end
  assign mem_rdata[1] = 32'b0;
`else
  simulator_ctrl #(
    .LogName("opensoc_top.log")
    ) u_simulator_ctrl (
      .clk_i     (clk_sys      ),
      .rst_ni    (rst_sys_n    ),

      .req_i     (mem_req[1]   ),
      .we_i      (mem_we[1]    ),
      .be_i      (mem_strb[1]  ),
      .addr_i    (mem_addr[1]  ),
      .wdata_i   (mem_wdata[1] ),
      .rvalid_o  (mem_rvalid[1]),
      .rdata_o   (mem_rdata[1] )
    );
`endif

  // -------------------------------------------------------------------------
  // Timer
  // -------------------------------------------------------------------------
  logic timer_err_unused;

  timer #(
    .DataWidth    (32),
    .AddressWidth (32)
    ) u_timer (
      .clk_i          (clk_sys         ),
      .rst_ni         (rst_sys_n       ),

      .timer_req_i    (mem_req[2]      ),
      .timer_we_i     (mem_we[2]       ),
      .timer_be_i     (mem_strb[2]     ),
      .timer_addr_i   (mem_addr[2]     ),
      .timer_wdata_i  (mem_wdata[2]    ),
      .timer_rvalid_o (mem_rvalid[2]   ),
      .timer_rdata_o  (mem_rdata[2]    ),
      .timer_err_o    (timer_err_unused),
      .timer_intr_o   (timer_irq       )
    );

  // -------------------------------------------------------------------------
  // UART
  // -------------------------------------------------------------------------
  uart u_uart (
    .clk_i     (clk_sys      ),
    .rst_ni    (rst_sys_n    ),

    .req_i     (mem_req[3]   ),
    .addr_i    (mem_addr[3]  ),
    .we_i      (mem_we[3]    ),
    .be_i      (mem_strb[3]  ),
    .wdata_i   (mem_wdata[3] ),
    .rvalid_o  (mem_rvalid[3]),
    .rdata_o   (mem_rdata[3] ),

    .irq_o     (uart_irq     ),

    .uart_tx_o (uart_tx_o    ),
    .uart_rx_i (uart_rx_i    )
  );

  // -------------------------------------------------------------------------
  // PIO (replaces GPIO — provides GPIO-compatible DIR/OUT/IN registers)
  // -------------------------------------------------------------------------
  pio u_pio (
    .clk_i          (clk_sys       ),
    .rst_ni         (rst_sys_n     ),

    .ctrl_req_i     (mem_req[4]    ),
    .ctrl_addr_i    (mem_addr[4]   ),
    .ctrl_we_i      (mem_we[4]     ),
    .ctrl_be_i      (mem_strb[4]   ),
    .ctrl_wdata_i   (mem_wdata[4]  ),
    .ctrl_rvalid_o  (mem_rvalid[4] ),
    .ctrl_rdata_o   (mem_rdata[4]  ),

    .dma_req_o      (pio_dma_req   ),
    .dma_addr_o     (pio_dma_addr  ),
    .dma_we_o       (pio_dma_we    ),
    .dma_wdata_o    (pio_dma_wdata ),
    .dma_be_o       (pio_dma_be    ),
    .dma_gnt_i      (pio_dma_gnt   ),
    .dma_rvalid_i   (pio_dma_rvalid),
    .dma_rdata_i    (pio_dma_rdata ),
    .dma_err_i      (pio_dma_err   ),

    .irq_o          (pio_irq       ),

    .gpio_i         (gpio_i        ),
    .gpio_o         (gpio_o        ),
    .gpio_oe        (gpio_oe       )
  );

  // -------------------------------------------------------------------------
  // I2C Controller
  // -------------------------------------------------------------------------
  i2c_controller u_i2c (
    .clk_i      (clk_sys      ),
    .rst_ni     (rst_sys_n    ),

    .req_i      (mem_req[5]   ),
    .addr_i     (mem_addr[5]  ),
    .we_i       (mem_we[5]    ),
    .be_i       (mem_strb[5]  ),
    .wdata_i    (mem_wdata[5] ),
    .rvalid_o   (mem_rvalid[5]),
    .rdata_o    (mem_rdata[5] ),

    .irq_o      (i2c_irq      ),

    .i2c_scl_o  (i2c_scl_o    ),
    .i2c_scl_oe (i2c_scl_oe   ),
    .i2c_scl_i  (i2c_scl_i    ),
    .i2c_sda_o  (i2c_sda_o    ),
    .i2c_sda_oe (i2c_sda_oe   ),
    .i2c_sda_i  (i2c_sda_i    )
  );

  // -------------------------------------------------------------------------
  // Crypto Cluster (OpenTitan AES via mem → TL-UL bridge)
  // -------------------------------------------------------------------------
  if (EnableCrypto) begin : gen_crypto
    crypto_cluster u_crypto (
      .clk_i     (clk_sys),
      .rst_ni    (rst_sys_n),

      .req_i     (mem_req[CryptoSlvIdx]),
      .addr_i    (mem_addr[CryptoSlvIdx]),
      .we_i      (mem_we[CryptoSlvIdx]),
      .be_i      (mem_strb[CryptoSlvIdx]),
      .wdata_i   (mem_wdata[CryptoSlvIdx]),
      .rvalid_o  (mem_rvalid[CryptoSlvIdx]),
      .rdata_o   (mem_rdata[CryptoSlvIdx]),

      .idle_o    ()
    );
  end

  // -------------------------------------------------------------------------
  // ReLU Accelerator (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableReLU) begin : gen_relu
    logic        relu_dma_req,   relu_dma_we,   relu_dma_gnt,  relu_dma_rvalid, relu_dma_err;
    logic [31:0] relu_dma_addr,  relu_dma_wdata, relu_dma_rdata;
    logic [3:0]  relu_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32              ),
      .AxiAddrWidth ( AxiAddrWidth    ),
      .DataWidth    ( AxiDataWidth    ),
      .MaxRequests  ( 2               ),
      .AxiProt      ( 3'b000          ),
      .axi_req_t    ( axi_in_req_t    ),
      .axi_rsp_t    ( axi_in_resp_t   )
    ) u_axi_from_mem_relu_dma (
      .clk_i          (clk_sys                      ),
      .rst_ni         (rst_sys_n                    ),
      .mem_req_i      (relu_dma_req                 ),
      .mem_addr_i      (relu_dma_addr               ),
      .mem_we_i        (relu_dma_we                 ),
      .mem_wdata_i     (relu_dma_wdata              ),
      .mem_be_i        (relu_dma_be                 ),
      .mem_gnt_o       (relu_dma_gnt                ),
      .mem_rsp_valid_o (relu_dma_rvalid             ),
      .mem_rsp_rdata_o (relu_dma_rdata              ),
      .mem_rsp_error_o (relu_dma_err                ),
      .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE   ),
      .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE   ),
      .axi_req_o       (xbar_slv_req[ReluDmaMstIdx] ),
      .axi_rsp_i       (xbar_slv_resp[ReluDmaMstIdx])
    );

    relu_accel u_relu_accel (
      .clk_i         (clk_sys               ),
      .rst_ni        (rst_sys_n             ),
      .ctrl_req_i    (mem_req[ReluSlvIdx]   ),
      .ctrl_addr_i   (mem_addr[ReluSlvIdx]  ),
      .ctrl_we_i     (mem_we[ReluSlvIdx]    ),
      .ctrl_be_i     (mem_strb[ReluSlvIdx]  ),
      .ctrl_wdata_i  (mem_wdata[ReluSlvIdx] ),
      .ctrl_rvalid_o (mem_rvalid[ReluSlvIdx]),
      .ctrl_rdata_o  (mem_rdata[ReluSlvIdx] ),
      .dma_req_o     (relu_dma_req          ),
      .dma_addr_o    (relu_dma_addr         ),
      .dma_we_o      (relu_dma_we           ),
      .dma_wdata_o   (relu_dma_wdata        ),
      .dma_be_o      (relu_dma_be           ),
      .dma_gnt_i     (relu_dma_gnt          ),
      .dma_rvalid_i  (relu_dma_rvalid       ),
      .dma_rdata_i   (relu_dma_rdata        ),
      .dma_err_i     (relu_dma_err          ),
      .irq_o         (relu_irq              )
    );
  end else begin : gen_no_relu
    assign relu_irq = 1'b0;
  end

  // -------------------------------------------------------------------------
  // Vector MAC Accelerator (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableVMAC) begin : gen_vmac
    logic        vmac_dma_req,   vmac_dma_we,   vmac_dma_gnt,  vmac_dma_rvalid, vmac_dma_err;
    logic [31:0] vmac_dma_addr,  vmac_dma_wdata, vmac_dma_rdata;
    logic [3:0]  vmac_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32            ),
      .AxiAddrWidth ( AxiAddrWidth  ),
      .DataWidth    ( AxiDataWidth  ),
      .MaxRequests  ( 2             ),
      .AxiProt      ( 3'b000        ),
      .axi_req_t    ( axi_in_req_t  ),
      .axi_rsp_t    ( axi_in_resp_t )
    ) u_axi_from_mem_vmac_dma (
      .clk_i(clk_sys                           ),
      .rst_ni(rst_sys_n                        ),
      .mem_req_i(vmac_dma_req                  ),
      .mem_addr_i(vmac_dma_addr                ),
      .mem_we_i(vmac_dma_we                    ),
      .mem_wdata_i(vmac_dma_wdata              ),
      .mem_be_i(vmac_dma_be                    ),
      .mem_gnt_o(vmac_dma_gnt                  ),
      .mem_rsp_valid_o(vmac_dma_rvalid         ),
      .mem_rsp_rdata_o(vmac_dma_rdata          ),
      .mem_rsp_error_o(vmac_dma_err            ),
      .slv_aw_cache_i(axi_pkg::CACHE_MODIFIABLE),
      .slv_ar_cache_i(axi_pkg::CACHE_MODIFIABLE),
      .axi_req_o(xbar_slv_req[VmacDmaMstIdx]   ),
      .axi_rsp_i(xbar_slv_resp[VmacDmaMstIdx]  )
    );

    vec_mac u_vec_mac (
      .clk_i        (clk_sys               ),
      .rst_ni       (rst_sys_n             ),
      .ctrl_req_i   (mem_req[VmacSlvIdx]   ),
      .ctrl_addr_i  (mem_addr[VmacSlvIdx]  ),
      .ctrl_we_i    (mem_we[VmacSlvIdx]    ),
      .ctrl_be_i    (mem_strb[VmacSlvIdx]  ),
      .ctrl_wdata_i (mem_wdata[VmacSlvIdx] ),
      .ctrl_rvalid_o(mem_rvalid[VmacSlvIdx]),
      .ctrl_rdata_o (mem_rdata[VmacSlvIdx] ),
      .dma_req_o    (vmac_dma_req          ),
      .dma_addr_o   (vmac_dma_addr         ),
      .dma_we_o     (vmac_dma_we           ),
      .dma_wdata_o  (vmac_dma_wdata        ),
      .dma_be_o     (vmac_dma_be           ),
      .dma_gnt_i    (vmac_dma_gnt          ),
      .dma_rvalid_i (vmac_dma_rvalid       ),
      .dma_rdata_i  (vmac_dma_rdata        ),
      .dma_err_i    (vmac_dma_err          ),
      .irq_o        (vmac_irq              )
    );
  end else begin : gen_no_vmac
    assign vmac_irq = 1'b0;
  end

  // -------------------------------------------------------------------------
  // Scatter-Gather DMA Engine (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableSgDma) begin : gen_sg_dma
    logic        sgdma_dma_req,   sgdma_dma_we,   sgdma_dma_gnt,  sgdma_dma_rvalid, sgdma_dma_err;
    logic [31:0] sgdma_dma_addr,  sgdma_dma_wdata, sgdma_dma_rdata;
    logic [3:0]  sgdma_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32            ),
      .AxiAddrWidth ( AxiAddrWidth  ),
      .DataWidth    ( AxiDataWidth  ),
      .MaxRequests  ( 2             ),
      .AxiProt      ( 3'b000        ),
      .axi_req_t    ( axi_in_req_t  ),
      .axi_rsp_t    ( axi_in_resp_t )
    ) u_axi_from_mem_sgdma (
      .clk_i           (clk_sys                       ),
      .rst_ni          (rst_sys_n                     ),
      .mem_req_i       (sgdma_dma_req                 ),
      .mem_addr_i      (sgdma_dma_addr                ),
      .mem_we_i        (sgdma_dma_we                  ),
      .mem_wdata_i     (sgdma_dma_wdata               ),
      .mem_be_i        (sgdma_dma_be                  ),
      .mem_gnt_o       (sgdma_dma_gnt                 ),
       .mem_rsp_valid_o(sgdma_dma_rvalid              ),
      .mem_rsp_rdata_o (sgdma_dma_rdata               ),
      .mem_rsp_error_o (sgdma_dma_err                 ),
      .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE     ),
      .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE     ),
      .axi_req_o       (xbar_slv_req[SgDmaDmaMstIdx]  ),
      .axi_rsp_i       (xbar_slv_resp[SgDmaDmaMstIdx] )
    );

    sg_dma u_sg_dma (
      .clk_i        (clk_sys                ),
      .rst_ni       (rst_sys_n              ),
      .ctrl_req_i   (mem_req[SgDmaSlvIdx]   ),
      .ctrl_addr_i  (mem_addr[SgDmaSlvIdx]  ),
      .ctrl_we_i    (mem_we[SgDmaSlvIdx]    ),
      .ctrl_be_i    (mem_strb[SgDmaSlvIdx]  ),
      .ctrl_wdata_i (mem_wdata[SgDmaSlvIdx] ),
      .ctrl_rvalid_o(mem_rvalid[SgDmaSlvIdx]),
      .ctrl_rdata_o (mem_rdata[SgDmaSlvIdx] ),
      .dma_req_o    (sgdma_dma_req          ),
      .dma_addr_o   (sgdma_dma_addr         ),
      .dma_we_o     (sgdma_dma_we           ),
      .dma_wdata_o  (sgdma_dma_wdata        ),
      .dma_be_o     (sgdma_dma_be           ),
      .dma_gnt_i    (sgdma_dma_gnt          ),
      .dma_rvalid_i (sgdma_dma_rvalid       ),
      .dma_rdata_i  (sgdma_dma_rdata        ),
      .dma_err_i    (sgdma_dma_err          ),
      .irq_o        (sg_dma_irq             )
    );
  end else begin : gen_no_sg_dma
    assign sg_dma_irq = 1'b0;
  end

  // -------------------------------------------------------------------------
  // Softmax Pipeline (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableSoftmax) begin : gen_softmax
    logic        smax_dma_req,   smax_dma_we,   smax_dma_gnt,  smax_dma_rvalid, smax_dma_err;
    logic [31:0] smax_dma_addr,  smax_dma_wdata, smax_dma_rdata;
    logic [3:0]  smax_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32            ),
      .AxiAddrWidth ( AxiAddrWidth  ),
      .DataWidth    ( AxiDataWidth  ),
      .MaxRequests  ( 2             ),
      .AxiProt      ( 3'b000        ),
      .axi_req_t    ( axi_in_req_t  ),
      .axi_rsp_t    ( axi_in_resp_t )
    ) u_axi_from_mem_smax_dma (
      .clk_i(clk_sys                           ),
      .rst_ni(rst_sys_n                        ),
      .mem_req_i(smax_dma_req                  ),
      .mem_addr_i(smax_dma_addr                ),
      .mem_we_i(smax_dma_we                    ),
      .mem_wdata_i(smax_dma_wdata              ),
      .mem_be_i(smax_dma_be                    ),
      .mem_gnt_o(smax_dma_gnt                  ),
      .mem_rsp_valid_o(smax_dma_rvalid         ),
      .mem_rsp_rdata_o(smax_dma_rdata          ),
      .mem_rsp_error_o(smax_dma_err            ),
      .slv_aw_cache_i(axi_pkg::CACHE_MODIFIABLE),
      .slv_ar_cache_i(axi_pkg::CACHE_MODIFIABLE),
      .axi_req_o(xbar_slv_req[SmaxDmaMstIdx]   ),
      .axi_rsp_i(xbar_slv_resp[SmaxDmaMstIdx]  )
    );

    softmax u_softmax (
      .clk_i        (clk_sys               ),
      .rst_ni       (rst_sys_n             ),
      .ctrl_req_i   (mem_req[SmaxSlvIdx]   ),
      .ctrl_addr_i  (mem_addr[SmaxSlvIdx]  ),
      .ctrl_we_i    (mem_we[SmaxSlvIdx]    ),
      .ctrl_be_i    (mem_strb[SmaxSlvIdx]  ),
      .ctrl_wdata_i (mem_wdata[SmaxSlvIdx] ),
      .ctrl_rvalid_o(mem_rvalid[SmaxSlvIdx]),
      .ctrl_rdata_o (mem_rdata[SmaxSlvIdx] ),
      .dma_req_o    (smax_dma_req          ),
      .dma_addr_o   (smax_dma_addr         ),
      .dma_we_o     (smax_dma_we           ),
      .dma_wdata_o  (smax_dma_wdata        ),
      .dma_be_o     (smax_dma_be           ),
      .dma_gnt_i    (smax_dma_gnt          ),
      .dma_rvalid_i (smax_dma_rvalid       ),
      .dma_rdata_i  (smax_dma_rdata        ),
      .dma_err_i    (smax_dma_err          ),
      .irq_o        (softmax_irq           )
    );
  end else begin : gen_no_softmax
    assign softmax_irq = 1'b0;
  end

  // -------------------------------------------------------------------------
  // Conv1D Engine (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableConv1d) begin : gen_conv1d
    logic        conv1d_dma_req,   conv1d_dma_we,   conv1d_dma_gnt,  conv1d_dma_rvalid, conv1d_dma_err;
    logic [31:0] conv1d_dma_addr,  conv1d_dma_wdata, conv1d_dma_rdata;
    logic [3:0]  conv1d_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32            ),
      .AxiAddrWidth ( AxiAddrWidth  ),
      .DataWidth    ( AxiDataWidth  ),
      .MaxRequests  ( 2             ),
      .AxiProt      ( 3'b000        ),
      .axi_req_t    ( axi_in_req_t  ),
      .axi_rsp_t    ( axi_in_resp_t )
    ) u_axi_from_mem_conv1d_dma (
      .clk_i           (clk_sys                          ),
      .rst_ni          (rst_sys_n                        ),
      .mem_req_i       (conv1d_dma_req                   ),
      .mem_addr_i      (conv1d_dma_addr                  ),
      .mem_we_i        (conv1d_dma_we                    ),
      .mem_wdata_i     (conv1d_dma_wdata                 ),
      .mem_be_i        (conv1d_dma_be                    ),
      .mem_gnt_o       (conv1d_dma_gnt                   ),
      .mem_rsp_valid_o (conv1d_dma_rvalid                ),
      .mem_rsp_rdata_o (conv1d_dma_rdata                 ),
      .mem_rsp_error_o (conv1d_dma_err                   ),
      .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE        ),
      .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE        ),
      .axi_req_o       (xbar_slv_req[Conv1dDmaMstIdx]    ),
      .axi_rsp_i       (xbar_slv_resp[Conv1dDmaMstIdx]   )
    );

    conv1d u_conv1d (
      .clk_i         (clk_sys                  ),
      .rst_ni        (rst_sys_n                ),
      .ctrl_req_i    (mem_req[Conv1dSlvIdx]    ),
      .ctrl_addr_i   (mem_addr[Conv1dSlvIdx]   ),
      .ctrl_we_i     (mem_we[Conv1dSlvIdx]     ),
      .ctrl_be_i     (mem_strb[Conv1dSlvIdx]   ),
      .ctrl_wdata_i  (mem_wdata[Conv1dSlvIdx]  ),
      .ctrl_rvalid_o (mem_rvalid[Conv1dSlvIdx] ),
      .ctrl_rdata_o  (mem_rdata[Conv1dSlvIdx]  ),
      .dma_req_o     (conv1d_dma_req           ),
      .dma_addr_o    (conv1d_dma_addr          ),
      .dma_we_o      (conv1d_dma_we            ),
      .dma_wdata_o   (conv1d_dma_wdata         ),
      .dma_be_o      (conv1d_dma_be            ),
      .dma_gnt_i     (conv1d_dma_gnt           ),
      .dma_rvalid_i  (conv1d_dma_rvalid        ),
      .dma_rdata_i   (conv1d_dma_rdata         ),
      .dma_err_i     (conv1d_dma_err           ),
      .irq_o         (conv1d_irq               )
    );
  end else begin : gen_no_conv1d
    assign conv1d_irq = 1'b0;
  end

endmodule

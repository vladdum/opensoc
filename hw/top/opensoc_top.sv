// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Originally based on ibex_simple_system from the Ibex project.
// Copyright lowRISC contributors.

`ifndef INSTR_CYCLE_DELAY
  `define INSTR_CYCLE_DELAY 0
`endif

`include "axi/assign.svh"

/**
 * OpenSoC Top-Level
 *
 * RISC-V SoC with the Kronos CPU core (native AXI4), a single-port SRAM,
 * and memory-mapped peripherals connected via a PULP AXI4 crossbar.
 *
 * The CPU instruction and data ports connect directly to the crossbar as
 * AXI4 masters. Accelerator DMA engines and the PIO DMA use OBI-to-AXI
 * bridges (axi_from_mem). All peripherals sit behind AXI-to-memory bridges
 * (axi_to_mem).
 */

module opensoc_top
  import axi_pkg::*;
  import opensoc_derived_config_pkg::*;
  import kronos_pkg::*;
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
  logic conv2d_irq;
  logic gemm_irq;
  logic [14:0] irq_fast;

  // -------------------------------------------------------------------------
  // Config 1 stream interconnect: Conv1D → ReLU
  // -------------------------------------------------------------------------
  logic        conv1d_to_relu_tvalid;
  logic        conv1d_to_relu_tready;
  logic [31:0] conv1d_to_relu_tdata;
  logic        conv1d_to_relu_tlast;

  // -------------------------------------------------------------------------
  // Config 2 stream interconnect: Conv2D → ReLU → Softmax
  // -------------------------------------------------------------------------
  logic        conv2d_to_relu_tvalid;
  logic        conv2d_to_relu_tready;
  logic [31:0] conv2d_to_relu_tdata;
  logic        conv2d_to_relu_tlast;

  logic        relu_to_smax_tvalid;
  logic        relu_to_smax_tready;
  logic [31:0] relu_to_smax_tdata;
  logic        relu_to_smax_tlast;

  // ReLU s_axis input: OR of Conv1D (Config 1) and Conv2D (Config 2).
  // Only one config runs at a time; inactive upstream will hold tvalid=0.
  logic        relu_s_axis_tvalid;
  logic        relu_s_axis_tready;
  logic [31:0] relu_s_axis_tdata;
  logic        relu_s_axis_tlast;

  assign relu_s_axis_tvalid = conv1d_to_relu_tvalid | conv2d_to_relu_tvalid;
  assign relu_s_axis_tdata  = conv1d_to_relu_tvalid ? conv1d_to_relu_tdata
                                                     : conv2d_to_relu_tdata;
  assign relu_s_axis_tlast  = conv1d_to_relu_tvalid ? conv1d_to_relu_tlast
                                                     : conv2d_to_relu_tlast;
  // Ready fans out to both upstreams; only one will be actively producing.
  assign conv1d_to_relu_tready = relu_s_axis_tready;
  assign conv2d_to_relu_tready = relu_s_axis_tready;

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
  // CPU instantiation: Kronos (native AXI4)
  // -------------------------------------------------------------------------
  assign irq_fast = {5'b0, gemm_irq, conv2d_irq, conv1d_irq, softmax_irq, sg_dma_irq, vmac_irq, relu_irq, i2c_irq, pio_irq, uart_irq};

  // -------------------------------------------------------------------------
  // Kronos RISC-V CPU (native AXI4 master ports)
  // -------------------------------------------------------------------------
  kronos_axi_req_t  kronos_instr_axi_req, kronos_data_axi_req;
  kronos_axi_resp_t kronos_instr_axi_rsp, kronos_data_axi_rsp;

  kronos_top u_top (
    .clk_i           (clk_sys),
    .rst_ni          (rst_sys_n),
    .instr_axi_req_o (kronos_instr_axi_req),
    .instr_axi_rsp_i (kronos_instr_axi_rsp),
    .data_axi_req_o  (kronos_data_axi_req),
    .data_axi_rsp_i  (kronos_data_axi_rsp),
    .irq_timer_i     (timer_irq),
    .irq_fast_i      (irq_fast),
    .boot_addr_i     (32'h20000080)
  );

  // Bridge Kronos AXI types → crossbar AXI types (struct-to-struct)
  `AXI_ASSIGN_REQ_STRUCT(xbar_slv_req[0], kronos_instr_axi_req)
  `AXI_ASSIGN_RESP_STRUCT(kronos_instr_axi_rsp, xbar_slv_resp[0])
  `AXI_ASSIGN_REQ_STRUCT(xbar_slv_req[1], kronos_data_axi_req)
  `AXI_ASSIGN_RESP_STRUCT(kronos_data_axi_rsp, xbar_slv_resp[1])

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
      .dma_err_i       (relu_dma_err              ),
      .s_axis_tvalid_i (relu_s_axis_tvalid        ),
      .s_axis_tready_o (relu_s_axis_tready        ),
      .s_axis_tdata_i  (relu_s_axis_tdata         ),
      .s_axis_tlast_i  (relu_s_axis_tlast         ),
      .m_axis_tvalid_o (relu_to_smax_tvalid       ),
      .m_axis_tready_i (relu_to_smax_tready       ),
      .m_axis_tdata_o  (relu_to_smax_tdata        ),
      .m_axis_tlast_o  (relu_to_smax_tlast        ),
      .irq_o           (relu_irq                  )
    );
  end else begin : gen_no_relu
    assign relu_irq              = 1'b0;
    assign relu_s_axis_tready   = 1'b0;
    assign relu_to_smax_tvalid  = 1'b0;
    assign relu_to_smax_tdata   = 32'd0;
    assign relu_to_smax_tlast   = 1'b0;
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
      .dma_err_i       (smax_dma_err            ),
      .s_axis_tvalid_i (relu_to_smax_tvalid     ),
      .s_axis_tready_o (relu_to_smax_tready     ),
      .s_axis_tdata_i  (relu_to_smax_tdata      ),
      .s_axis_tlast_i  (relu_to_smax_tlast      ),
      .irq_o           (softmax_irq             )
    );
  end else begin : gen_no_softmax
    assign softmax_irq        = 1'b0;
    assign relu_to_smax_tready = 1'b0;
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
      .dma_err_i       (conv1d_dma_err              ),
      .m_axis_tvalid_o (conv1d_to_relu_tvalid      ),
      .m_axis_tready_i (conv1d_to_relu_tready      ),
      .m_axis_tdata_o  (conv1d_to_relu_tdata       ),
      .m_axis_tlast_o  (conv1d_to_relu_tlast       ),
      .irq_o           (conv1d_irq                 )
    );
  end else begin : gen_no_conv1d
    assign conv1d_irq            = 1'b0;
    assign conv1d_to_relu_tvalid = 1'b0;
    assign conv1d_to_relu_tdata  = 32'd0;
    assign conv1d_to_relu_tlast  = 1'b0;
  end

  // -------------------------------------------------------------------------
  // Conv2D Engine (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableConv2d) begin : gen_conv2d
    logic        conv2d_dma_req,   conv2d_dma_we,   conv2d_dma_gnt,  conv2d_dma_rvalid, conv2d_dma_err;
    logic [31:0] conv2d_dma_addr,  conv2d_dma_wdata, conv2d_dma_rdata;
    logic [3:0]  conv2d_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32            ),
      .AxiAddrWidth ( AxiAddrWidth  ),
      .DataWidth    ( AxiDataWidth  ),
      .MaxRequests  ( 2             ),
      .AxiProt      ( 3'b000        ),
      .axi_req_t    ( axi_in_req_t  ),
      .axi_rsp_t    ( axi_in_resp_t )
    ) u_axi_from_mem_conv2d_dma (
      .clk_i           (clk_sys                          ),
      .rst_ni          (rst_sys_n                        ),
      .mem_req_i       (conv2d_dma_req                   ),
      .mem_addr_i      (conv2d_dma_addr                  ),
      .mem_we_i        (conv2d_dma_we                    ),
      .mem_wdata_i     (conv2d_dma_wdata                 ),
      .mem_be_i        (conv2d_dma_be                    ),
      .mem_gnt_o       (conv2d_dma_gnt                   ),
      .mem_rsp_valid_o (conv2d_dma_rvalid                ),
      .mem_rsp_rdata_o (conv2d_dma_rdata                 ),
      .mem_rsp_error_o (conv2d_dma_err                   ),
      .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE        ),
      .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE        ),
      .axi_req_o       (xbar_slv_req[Conv2dDmaMstIdx]    ),
      .axi_rsp_i       (xbar_slv_resp[Conv2dDmaMstIdx]   )
    );

    conv2d u_conv2d (
      .clk_i           (clk_sys                     ),
      .rst_ni          (rst_sys_n                   ),
      .ctrl_req_i      (mem_req[Conv2dSlvIdx]       ),
      .ctrl_addr_i     (mem_addr[Conv2dSlvIdx]      ),
      .ctrl_we_i       (mem_we[Conv2dSlvIdx]        ),
      .ctrl_be_i       (mem_strb[Conv2dSlvIdx]      ),
      .ctrl_wdata_i    (mem_wdata[Conv2dSlvIdx]     ),
      .ctrl_rvalid_o   (mem_rvalid[Conv2dSlvIdx]    ),
      .ctrl_rdata_o    (mem_rdata[Conv2dSlvIdx]     ),
      .dma_req_o       (conv2d_dma_req              ),
      .dma_addr_o      (conv2d_dma_addr             ),
      .dma_we_o        (conv2d_dma_we               ),
      .dma_wdata_o     (conv2d_dma_wdata            ),
      .dma_be_o        (conv2d_dma_be               ),
      .dma_gnt_i       (conv2d_dma_gnt              ),
      .dma_rvalid_i    (conv2d_dma_rvalid           ),
      .dma_rdata_i     (conv2d_dma_rdata            ),
      .dma_err_i       (conv2d_dma_err              ),
      .m_axis_tvalid_o (conv2d_to_relu_tvalid       ),
      .m_axis_tready_i (conv2d_to_relu_tready       ),
      .m_axis_tdata_o  (conv2d_to_relu_tdata        ),
      .m_axis_tlast_o  (conv2d_to_relu_tlast        ),
      .irq_o           (conv2d_irq                  )
    );
  end else begin : gen_no_conv2d
    assign conv2d_irq            = 1'b0;
    assign conv2d_to_relu_tvalid = 1'b0;
    assign conv2d_to_relu_tdata  = 32'd0;
    assign conv2d_to_relu_tlast  = 1'b0;
  end

  // -------------------------------------------------------------------------
  // GEMM Accelerator (DMA bridge + instance)
  // -------------------------------------------------------------------------
  if (EnableGemm) begin : gen_gemm
    logic        gemm_dma_req,   gemm_dma_we,   gemm_dma_gnt,  gemm_dma_rvalid, gemm_dma_err;
    logic [31:0] gemm_dma_addr,  gemm_dma_wdata, gemm_dma_rdata;
    logic [3:0]  gemm_dma_be;

    axi_from_mem #(
      .MemAddrWidth ( 32            ),
      .AxiAddrWidth ( AxiAddrWidth  ),
      .DataWidth    ( AxiDataWidth  ),
      .MaxRequests  ( 2             ),
      .AxiProt      ( 3'b000        ),
      .axi_req_t    ( axi_in_req_t  ),
      .axi_rsp_t    ( axi_in_resp_t )
    ) u_axi_from_mem_gemm_dma (
      .clk_i           (clk_sys                         ),
      .rst_ni          (rst_sys_n                       ),
      .mem_req_i       (gemm_dma_req                    ),
      .mem_addr_i      (gemm_dma_addr                   ),
      .mem_we_i        (gemm_dma_we                     ),
      .mem_wdata_i     (gemm_dma_wdata                  ),
      .mem_be_i        (gemm_dma_be                     ),
      .mem_gnt_o       (gemm_dma_gnt                    ),
      .mem_rsp_valid_o (gemm_dma_rvalid                 ),
      .mem_rsp_rdata_o (gemm_dma_rdata                  ),
      .mem_rsp_error_o (gemm_dma_err                    ),
      .slv_aw_cache_i  (axi_pkg::CACHE_MODIFIABLE       ),
      .slv_ar_cache_i  (axi_pkg::CACHE_MODIFIABLE       ),
      .axi_req_o       (xbar_slv_req[GemmDmaMstIdx]     ),
      .axi_rsp_i       (xbar_slv_resp[GemmDmaMstIdx]    )
    );

    gemm u_gemm (
      .clk_i         (clk_sys                 ),
      .rst_ni        (rst_sys_n               ),
      .ctrl_req_i    (mem_req[GemmSlvIdx]     ),
      .ctrl_addr_i   (mem_addr[GemmSlvIdx]    ),
      .ctrl_we_i     (mem_we[GemmSlvIdx]      ),
      .ctrl_be_i     (mem_strb[GemmSlvIdx]    ),
      .ctrl_wdata_i  (mem_wdata[GemmSlvIdx]   ),
      .ctrl_rvalid_o (mem_rvalid[GemmSlvIdx]  ),
      .ctrl_rdata_o  (mem_rdata[GemmSlvIdx]   ),
      .dma_req_o     (gemm_dma_req            ),
      .dma_addr_o    (gemm_dma_addr           ),
      .dma_we_o      (gemm_dma_we             ),
      .dma_wdata_o   (gemm_dma_wdata          ),
      .dma_be_o      (gemm_dma_be             ),
      .dma_gnt_i     (gemm_dma_gnt            ),
      .dma_rvalid_i  (gemm_dma_rvalid         ),
      .dma_rdata_i   (gemm_dma_rdata          ),
      .dma_err_i     (gemm_dma_err            ),
      .irq_o         (gemm_irq                )
    );
  end else begin : gen_no_gemm
    assign gemm_irq = 1'b0;
  end

endmodule

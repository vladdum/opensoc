// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * ReLU Accelerator with DMA
 *
 * Applies the ReLU activation function (max(0, x)) to an array of 32-bit
 * signed integers in memory. Wraps dma_accel_core with a one-line
 * combinational processing function.
 *
 * To create a new accelerator, copy this file and replace the ReLU logic
 * with your own function between proc_data and proc_result.
 */
module relu_accel (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Control register bus (from axi_to_mem)
  input  logic        ctrl_req_i,
  input  logic [31:0] ctrl_addr_i,
  input  logic        ctrl_we_i,
  input  logic [3:0]  ctrl_be_i,
  input  logic [31:0] ctrl_wdata_i,
  output logic        ctrl_rvalid_o,
  output logic [31:0] ctrl_rdata_o,

  // DMA bus (to axi_from_mem)
  output logic        dma_req_o,
  output logic [31:0] dma_addr_o,
  output logic        dma_we_o,
  output logic [31:0] dma_wdata_o,
  output logic [3:0]  dma_be_o,
  input  logic        dma_gnt_i,
  input  logic        dma_rvalid_i,
  input  logic [31:0] dma_rdata_i,
  input  logic        dma_err_i,

  // AXI-Stream input (stream in mode only, ignored in DMA mode)
  input  logic        s_axis_tvalid_i,
  output logic        s_axis_tready_o,
  input  logic [31:0] s_axis_tdata_i,
  input  logic        s_axis_tlast_i,

  // AXI-Stream output (stream out mode only, idle in DMA mode)
  output logic        m_axis_tvalid_o,
  input  logic        m_axis_tready_i,
  output logic [31:0] m_axis_tdata_o,
  output logic        m_axis_tlast_o,

  // Interrupt
  output logic        irq_o
);

  // Processing interface: DMA core ↔ ReLU function
  logic [31:0] proc_data;
  logic [31:0] proc_result;

  // ---------------------------------------------------------------------------
  // ReLU: max(0, x) — replace this for a different accelerator
  // ---------------------------------------------------------------------------
  assign proc_result = proc_data[31] ? 32'd0 : proc_data;

  // ---------------------------------------------------------------------------
  // DMA accelerator framework
  // ---------------------------------------------------------------------------
  dma_accel_core u_dma_core (
    .clk_i,
    .rst_ni,

    .ctrl_req_i,
    .ctrl_addr_i,
    .ctrl_we_i,
    .ctrl_be_i,
    .ctrl_wdata_i,
    .ctrl_rvalid_o,
    .ctrl_rdata_o,

    .dma_req_o,
    .dma_addr_o,
    .dma_we_o,
    .dma_wdata_o,
    .dma_be_o,
    .dma_gnt_i,
    .dma_rvalid_i,
    .dma_rdata_i,
    .dma_err_i,

    .s_axis_tvalid_i,
    .s_axis_tready_o,
    .s_axis_tdata_i,
    .s_axis_tlast_i,

    .m_axis_tvalid_o,
    .m_axis_tready_i,
    .m_axis_tdata_o,
    .m_axis_tlast_o,

    .proc_data_o   (proc_data),
    .proc_result_i (proc_result),

    .irq_o
  );

endmodule

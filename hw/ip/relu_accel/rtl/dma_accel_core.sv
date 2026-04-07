// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Generic DMA Accelerator Core
 *
 * Reusable read-process-write DMA engine. The CPU configures source/destination
 * addresses and length via control registers, then triggers the operation. The
 * engine reads each word from RAM, presents it on proc_data_o, captures the
 * result from proc_result_i, and writes it back. An interrupt fires on
 * completion.
 *
 * To build a new accelerator, instantiate this module and connect a
 * combinational processing function between proc_data_o and proc_result_i.
 *
 * Control registers (offset from base):
 *   0x00  SRC_ADDR  - Source address in RAM (R/W, DMA mode only)
 *   0x04  DST_ADDR  - Destination address in RAM (R/W)
 *   0x08  LEN       - Number of 32-bit words to process (R/W)
 *   0x0C  CTRL      - [0] GO: write 1 to start (W, ignored if busy)
 *                     [2] STREAM_IN:  1=accept input from AXI-Stream slave
 *                     [3] STREAM_OUT: 1=emit output to AXI-Stream master
 *   0x10  STATUS    - [0] BUSY, [1] DONE (R)
 *   0x14  IER       - [0] Done interrupt enable (R/W)
 *
 * DMA interface uses the same memory-port protocol as Ibex (req/gnt/rvalid),
 * bridged to AXI via axi_from_mem in the top level.
 *
 * Stream input mode (CTRL[2]=1):
 *   Skips the DMA read phase. Instead, waits for data on s_axis_* and applies
 *   the processing function to each incoming beat, writing results to DST_ADDR
 *   via DMA as normal. LEN must match the number of beats the upstream producer
 *   will send.
 *
 * Stream output mode (CTRL[3]=1):
 *   Skips the DMA write phase. Instead, emits processed results on m_axis_*.
 *   Can be combined with CTRL[2]=1 for full-stream (no DMA at all).
 */
module dma_accel_core (
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

  // AXI-Stream input (stream mode only, ignored in DMA mode)
  input  logic        s_axis_tvalid_i,
  output logic        s_axis_tready_o,
  input  logic [31:0] s_axis_tdata_i,
  input  logic        s_axis_tlast_i,

  // AXI-Stream master output (stream output mode only, idle otherwise)
  output logic        m_axis_tvalid_o,
  input  logic        m_axis_tready_i,
  output logic [31:0] m_axis_tdata_o,
  output logic        m_axis_tlast_o,

  // Processing interface (combinational)
  output logic [31:0] proc_data_o,    // data read from memory or stream
  input  logic [31:0] proc_result_i,  // processed result to write back

  // Interrupt
  output logic        irq_o
);

  // ---------------------------------------------------------------------------
  // Register offsets (10-bit, matching 1 kB address window)
  // ---------------------------------------------------------------------------
  localparam logic [9:0] REG_SRC_ADDR = 10'h000;
  localparam logic [9:0] REG_DST_ADDR = 10'h004;
  localparam logic [9:0] REG_LEN      = 10'h008;
  localparam logic [9:0] REG_CTRL     = 10'h00C;
  localparam logic [9:0] REG_STATUS   = 10'h010;
  localparam logic [9:0] REG_IER      = 10'h014;

  // ---------------------------------------------------------------------------
  // Configuration registers
  // ---------------------------------------------------------------------------
  logic [31:0] src_addr_q, dst_addr_q, len_q;
  logic        ier_done_q;
  logic        mode_q;      // 0=DMA in, 1=Stream in
  logic        mode_out_q;  // 0=DMA out, 1=Stream out

  // ---------------------------------------------------------------------------
  // Status flags
  // ---------------------------------------------------------------------------
  logic busy_q, done_q;

  // ---------------------------------------------------------------------------
  // DMA working state
  // ---------------------------------------------------------------------------
  logic [31:0] cur_src_q, cur_dst_q, remaining_q;
  logic [31:0] proc_result_q;

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    RD_REQ,
    RD_WAIT,
    STREAM_IN,
    WR_REQ,
    WR_WAIT,
    MAXIS_OUT
  } state_e;

  state_e state_q, state_d;

  // GO pulse: valid only when not busy
  logic go;
  assign go = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
              & ctrl_wdata_i[0] & ~busy_q;

  // Interrupt output: level-sensitive, active when done and enabled
  assign irq_o = done_q & ier_done_q;

  // DMA byte enables: always full-word
  assign dma_be_o = 4'b1111;

  // Stream ready: accept beats only when waiting in STREAM_IN
  assign s_axis_tready_o = (state_q == STREAM_IN);

  // AXI-Stream master output: driven from MAXIS_OUT state
  assign m_axis_tvalid_o = (state_q == MAXIS_OUT);
  assign m_axis_tdata_o  = proc_result_q;
  assign m_axis_tlast_o  = (state_q == MAXIS_OUT) & (remaining_q == 32'd1);

  // Processing interface: data comes from DMA read or stream beat
  assign proc_data_o = (state_q == STREAM_IN) ? s_axis_tdata_i : dma_rdata_i;

  // ---------------------------------------------------------------------------
  // Control register read path
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_rvalid_o <= 1'b0;
      ctrl_rdata_o  <= 32'd0;
    end else begin
      ctrl_rvalid_o <= ctrl_req_i;
      ctrl_rdata_o  <= 32'd0;
      if (ctrl_req_i && !ctrl_we_i) begin
        case (ctrl_addr_i[9:0])
          REG_SRC_ADDR: ctrl_rdata_o <= src_addr_q;
          REG_DST_ADDR: ctrl_rdata_o <= dst_addr_q;
          REG_LEN:      ctrl_rdata_o <= len_q;
          REG_CTRL:     ctrl_rdata_o <= {28'd0, mode_out_q, mode_q, 2'b00};
          REG_STATUS:   ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_IER:      ctrl_rdata_o <= {31'd0, ier_done_q};
          default:      ctrl_rdata_o <= 32'd0;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Control register write path
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_addr_q <= 32'd0;
      dst_addr_q <= 32'd0;
      len_q      <= 32'd0;
      ier_done_q <= 1'b0;
      mode_q     <= 1'b0;
      mode_out_q <= 1'b0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_SRC_ADDR: src_addr_q <= ctrl_wdata_i;
        REG_DST_ADDR: dst_addr_q <= ctrl_wdata_i;
        REG_LEN:      len_q      <= ctrl_wdata_i;
        REG_CTRL:     begin
          mode_q     <= ctrl_wdata_i[2];
          mode_out_q <= ctrl_wdata_i[3];
        end
        REG_IER:      ier_done_q <= ctrl_wdata_i[0];
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — next-state and output logic
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;

    case (state_q)
      IDLE: begin
        if (go && len_q != 32'd0)
          // Use incoming write data directly: mode_q hasn't clocked in yet
          // when go fires (both come from the same register write).
          state_d = ctrl_wdata_i[2] ? STREAM_IN : RD_REQ;
      end

      RD_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = cur_src_q;
        if (dma_gnt_i) state_d = RD_WAIT;
      end

      RD_WAIT: begin
        if (dma_rvalid_i) state_d = mode_out_q ? MAXIS_OUT : WR_REQ;
      end

      STREAM_IN: begin
        // Wait for a valid beat from the upstream producer
        if (s_axis_tvalid_i) state_d = mode_out_q ? MAXIS_OUT : WR_REQ;
      end

      WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = cur_dst_q;
        dma_we_o    = 1'b1;
        dma_wdata_o = proc_result_q;
        if (dma_gnt_i) state_d = WR_WAIT;
      end

      WR_WAIT: begin
        if (dma_rvalid_i) begin
          state_d = (remaining_q == 32'd1) ? IDLE
                  : (mode_q ? STREAM_IN : RD_REQ);
        end
      end

      MAXIS_OUT: begin
        // Emit processed result on AXI-Stream master; hold until accepted
        if (m_axis_tready_i) begin
          state_d = (remaining_q == 32'd1) ? IDLE
                  : (mode_q ? STREAM_IN : RD_REQ);
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — sequential state and working registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= IDLE;
      busy_q        <= 1'b0;
      done_q        <= 1'b0;
      cur_src_q     <= 32'd0;
      cur_dst_q     <= 32'd0;
      remaining_q   <= 32'd0;
      proc_result_q <= 32'd0;
    end else begin
      state_q <= state_d;

      case (state_q)
        IDLE: begin
          if (go && len_q != 32'd0) begin
            busy_q      <= 1'b1;
            done_q      <= 1'b0;
            cur_src_q   <= src_addr_q;
            cur_dst_q   <= dst_addr_q;
            remaining_q <= len_q;
          end else if (go) begin
            done_q <= 1'b1;
          end
        end

        RD_WAIT: begin
          if (dma_rvalid_i) begin
            proc_result_q <= proc_result_i;
          end
        end

        STREAM_IN: begin
          if (s_axis_tvalid_i) begin
            proc_result_q <= proc_result_i;
          end
        end

        WR_WAIT: begin
          if (dma_rvalid_i) begin
            cur_src_q   <= cur_src_q + 32'd4;
            cur_dst_q   <= cur_dst_q + 32'd4;
            remaining_q <= remaining_q - 32'd1;
            if (remaining_q == 32'd1) begin
              busy_q <= 1'b0;
              done_q <= 1'b1;
            end
          end
        end

        MAXIS_OUT: begin
          if (m_axis_tready_i) begin
            cur_src_q   <= cur_src_q + 32'd4;
            remaining_q <= remaining_q - 32'd1;
            if (remaining_q == 32'd1) begin
              busy_q <= 1'b0;
              done_q <= 1'b1;
            end
          end
        end

        default: ;
      endcase
    end
  end

endmodule

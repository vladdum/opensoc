// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 1D Convolution Engine with DMA
 *
 * Computes y[n] = sum(x[n+k] * w[k], k=0..KERNEL_SIZE-1) for a stream of
 * INT8 input samples read from DRAM via DMA. Outputs are INT32 values written
 * back to DRAM (DMA mode) or forwarded via AXI-Stream (stream mode).
 *
 * Each input sample occupies one 32-bit word in memory (byte 0 used, bytes
 * 1-3 ignored). Each output occupies one 32-bit word.
 *
 * Two padding modes:
 *   Valid-only (PADDING_MODE=0x00): output length = LENGTH - KERNEL_SIZE + 1.
 *     First output produced after KERNEL_SIZE real reads.
 *   Same/zero-pad (PADDING_MODE=0x03): output length = LENGTH.
 *     Shift register is initialized as if (KERNEL_SIZE-1) zero samples were
 *     pre-loaded, so the first real read produces the first output immediately.
 *
 * PE bypass: the PE receives the incoming sample combinationally (before the
 * shift register has clocked it in) alongside the current shift register state,
 * so the result is valid in the same cycle as dma_rvalid_i and can be captured
 * on the same rising edge.
 *
 * Control registers (offset from base):
 *   0x00  CTRL         W     [0]=GO, [1]=SOFT_RESET, [2]=STREAM_MODE
 *   0x04  STATUS       R     [0]=BUSY, [1]=DONE
 *   0x08  SRC_ADDR    R/W    Input buffer base address (word-aligned)
 *   0x0C  DST_ADDR    R/W    Output buffer base address (word-aligned, DMA mode only)
 *   0x10  LENGTH      R/W    Number of INT8 input samples
 *   0x14  IER         R/W    [0] IRQ enable on completion
 *   0x18  KERNEL_SIZE R/W    Active kernel taps (1..16)
 *   0x1C  PADDING_MODE R/W   [0]=ZERO_PAD, [1]=SAME
 *   0x20–0x5C  KERNEL_W[0..15]  R/W  INT8 weights (sign-extended to 32 bits)
 *
 * Stream mode (CTRL[2]=1):
 *   Reads input from DMA as normal, but instead of writing results back to
 *   DRAM, outputs each result via AXI-Stream (m_axis_*). The downstream
 *   consumer provides backpressure via m_axis_tready_i.
 */
module conv1d (
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

  // AXI-Stream output (stream mode only, idle in DMA mode)
  output logic        m_axis_tvalid_o,
  input  logic        m_axis_tready_i,
  output logic [31:0] m_axis_tdata_o,
  output logic        m_axis_tlast_o,

  // Interrupt
  output logic        irq_o
);

  // -------------------------------------------------------------------------
  // Register offsets
  // -------------------------------------------------------------------------
  localparam logic [9:0] REG_CTRL         = 10'h000;
  localparam logic [9:0] REG_STATUS       = 10'h004;
  localparam logic [9:0] REG_SRC_ADDR     = 10'h008;
  localparam logic [9:0] REG_DST_ADDR     = 10'h00C;
  localparam logic [9:0] REG_LENGTH       = 10'h010;
  localparam logic [9:0] REG_IER          = 10'h014;
  localparam logic [9:0] REG_KERNEL_SIZE  = 10'h018;
  localparam logic [9:0] REG_PADDING_MODE = 10'h01C;
  // KERNEL_W[n] at offset 0x20 + n*4

  localparam int unsigned MAX_KERNEL = 16;

  // -------------------------------------------------------------------------
  // Configuration registers
  // -------------------------------------------------------------------------
  logic [31:0] src_addr_q, dst_addr_q, length_q;
  logic        ier_done_q;
  logic [31:0] kernel_size_q;    // 1..16 stored as 32-bit
  logic        zero_pad_q, same_q;
  logic        mode_q;           // 0=DMA, 1=Stream
  logic signed [7:0] kernel_w_q [MAX_KERNEL];

  // -------------------------------------------------------------------------
  // Status flags
  // -------------------------------------------------------------------------
  logic busy_q, done_q;

  // -------------------------------------------------------------------------
  // DMA / FSM working state
  // -------------------------------------------------------------------------
  logic [31:0] cur_src_q, cur_dst_q;
  logic [31:0] fill_count_q;     // samples seen (real + virtual pre-fill zeros)
  logic [31:0] wr_remaining_q;   // output elements yet to write/stream
  logic [31:0] pe_result_q;      // captured PE result for write/stream

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    RD_REQ,
    RD_WAIT,
    WR_REQ,
    WR_WAIT,
    STREAM_OUT
  } state_e;

  state_e state_q, state_d;

  // GO / SOFT_RESET pulse decode
  logic go, soft_reset;
  assign go         = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
                      & ctrl_wdata_i[0] & ~busy_q;
  assign soft_reset = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
                      & ctrl_wdata_i[1];

  // Interrupt output
  assign irq_o = done_q & ier_done_q;

  // DMA byte enables: always full-word
  assign dma_be_o = 4'b1111;

  // AXI-Stream output: driven from STREAM_OUT state
  assign m_axis_tvalid_o = (state_q == STREAM_OUT);
  assign m_axis_tdata_o  = pe_result_q;
  assign m_axis_tlast_o  = (state_q == STREAM_OUT) & (wr_remaining_q == 32'd1);

  // -------------------------------------------------------------------------
  // Shift register
  // -------------------------------------------------------------------------
  logic             shift_load;
  logic             shift_clr;
  logic signed [7:0] shift_out [MAX_KERNEL];

  assign shift_load = (state_q == RD_WAIT) & dma_rvalid_i;
  assign shift_clr  = soft_reset;

  conv1d_shift_reg #(
    .DEPTH ( MAX_KERNEL ),
    .WIDTH ( 8          )
  ) u_shift_reg (
    .clk_i  (clk_i                     ),
    .rst_ni (rst_ni                    ),
    .clr_i  (shift_clr                 ),
    .load_i (shift_load                ),
    .data_i (signed'(dma_rdata_i[7:0]) ),
    .regs_o (shift_out                 )
  );

  // -------------------------------------------------------------------------
  // PE bypass: compute result using the *incoming* sample at reg[0], so the
  // result is valid in the same cycle as dma_rvalid_i (before the shift reg
  // clocks the new sample in).
  // -------------------------------------------------------------------------
  logic signed [7:0] vregs [MAX_KERNEL];
  assign vregs[0] = signed'(dma_rdata_i[7:0]);
  for (genvar i = 1; i < MAX_KERNEL; i++) begin : gen_vregs
    assign vregs[i] = shift_out[i-1];
  end

  logic signed [31:0] pe_result_comb;

  conv1d_pe #(
    .MAX_KERNEL ( MAX_KERNEL )
  ) u_pe (
    .regs_i        (vregs              ),
    .weights_i     (kernel_w_q         ),
    .kernel_size_i (kernel_size_q[4:0] ),
    .result_o      (pe_result_comb     )
  );

  // -------------------------------------------------------------------------
  // Control register read path
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_rvalid_o <= 1'b0;
      ctrl_rdata_o  <= 32'd0;
    end else begin
      ctrl_rvalid_o <= ctrl_req_i;
      ctrl_rdata_o  <= 32'd0;
      if (ctrl_req_i && !ctrl_we_i) begin
        case (ctrl_addr_i[9:0])
          REG_CTRL:         ctrl_rdata_o <= {29'd0, mode_q, 2'b00};
          REG_STATUS:       ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_SRC_ADDR:     ctrl_rdata_o <= src_addr_q;
          REG_DST_ADDR:     ctrl_rdata_o <= dst_addr_q;
          REG_LENGTH:       ctrl_rdata_o <= length_q;
          REG_IER:          ctrl_rdata_o <= {31'd0, ier_done_q};
          REG_KERNEL_SIZE:  ctrl_rdata_o <= kernel_size_q;
          REG_PADDING_MODE: ctrl_rdata_o <= {30'd0, same_q, zero_pad_q};
          default: begin
            if (ctrl_addr_i[9:0] >= 10'h020 && ctrl_addr_i[9:0] <= 10'h05C) begin
              automatic int unsigned widx;
              widx = (32'(ctrl_addr_i[9:2]) - 32'h08);
              if (widx < MAX_KERNEL)
                ctrl_rdata_o <= {{24{kernel_w_q[widx][7]}}, kernel_w_q[widx]};
            end
          end
        endcase
      end
    end
  end

  // -------------------------------------------------------------------------
  // Control register write path
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_addr_q    <= 32'd0;
      dst_addr_q    <= 32'd0;
      length_q      <= 32'd0;
      ier_done_q    <= 1'b0;
      kernel_size_q <= 32'd1;
      zero_pad_q    <= 1'b0;
      same_q        <= 1'b0;
      mode_q        <= 1'b0;
      for (int i = 0; i < MAX_KERNEL; i++) kernel_w_q[i] <= '0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_CTRL:         mode_q        <= ctrl_wdata_i[2];
        REG_SRC_ADDR:     src_addr_q    <= ctrl_wdata_i;
        REG_DST_ADDR:     dst_addr_q    <= ctrl_wdata_i;
        REG_LENGTH:       length_q      <= ctrl_wdata_i;
        REG_IER:          ier_done_q    <= ctrl_wdata_i[0];
        REG_KERNEL_SIZE:  kernel_size_q <= ctrl_wdata_i;
        REG_PADDING_MODE: begin
          zero_pad_q <= ctrl_wdata_i[0];
          same_q     <= ctrl_wdata_i[1];
        end
        default: begin
          if (ctrl_addr_i[9:0] >= 10'h020 && ctrl_addr_i[9:0] <= 10'h05C) begin
            automatic int unsigned widx;
            widx = (32'(ctrl_addr_i[9:2]) - 32'h08);
            if (widx < MAX_KERNEL)
              kernel_w_q[widx] <= signed'(ctrl_wdata_i[7:0]);
          end
        end
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // FSM — next-state and combinational DMA outputs
  // -------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;

    case (state_q)
      IDLE: begin
        if (go && length_q != 32'd0) state_d = RD_REQ;
      end

      RD_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = cur_src_q;
        if (dma_gnt_i) state_d = RD_WAIT;
      end

      RD_WAIT: begin
        if (dma_rvalid_i) begin
          if ((fill_count_q + 32'd1) >= kernel_size_q) begin
            state_d = mode_q ? STREAM_OUT : WR_REQ;
          end else begin
            state_d = RD_REQ;
          end
        end
      end

      WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = cur_dst_q;
        dma_we_o    = 1'b1;
        dma_wdata_o = pe_result_q;
        if (dma_gnt_i) state_d = WR_WAIT;
      end

      WR_WAIT: begin
        if (dma_rvalid_i) begin
          state_d = (wr_remaining_q == 32'd1) ? IDLE : RD_REQ;
        end
      end

      STREAM_OUT: begin
        if (m_axis_tready_i) begin
          state_d = (wr_remaining_q == 32'd1) ? IDLE : RD_REQ;
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // FSM — sequential state and working registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= IDLE;
      busy_q         <= 1'b0;
      done_q         <= 1'b0;
      cur_src_q      <= 32'd0;
      cur_dst_q      <= 32'd0;
      fill_count_q   <= 32'd0;
      wr_remaining_q <= 32'd0;
      pe_result_q    <= 32'd0;
    end else begin
      state_q <= state_d;

      if (soft_reset) begin
        busy_q         <= 1'b0;
        done_q         <= 1'b0;
        fill_count_q   <= 32'd0;
        wr_remaining_q <= 32'd0;
      end

      case (state_q)
        IDLE: begin
          if (go && length_q != 32'd0) begin
            busy_q         <= 1'b1;
            done_q         <= 1'b0;
            cur_src_q      <= src_addr_q;
            cur_dst_q      <= dst_addr_q;
            fill_count_q   <= same_q ? (kernel_size_q - 32'd1) : 32'd0;
            wr_remaining_q <= same_q ? length_q
                                     : (length_q - kernel_size_q + 32'd1);
          end else if (go) begin
            done_q <= 1'b1;
          end
        end

        RD_WAIT: begin
          if (dma_rvalid_i) begin
            pe_result_q  <= pe_result_comb;
            fill_count_q <= fill_count_q + 32'd1;
            cur_src_q    <= cur_src_q + 32'd4;
          end
        end

        WR_WAIT: begin
          if (dma_rvalid_i) begin
            cur_dst_q      <= cur_dst_q + 32'd4;
            wr_remaining_q <= wr_remaining_q - 32'd1;
            if (wr_remaining_q == 32'd1) begin
              busy_q <= 1'b0;
              done_q <= 1'b1;
            end
          end
        end

        STREAM_OUT: begin
          if (m_axis_tready_i) begin
            wr_remaining_q <= wr_remaining_q - 32'd1;
            if (wr_remaining_q == 32'd1) begin
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

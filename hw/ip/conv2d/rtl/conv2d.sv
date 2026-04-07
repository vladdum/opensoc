// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 2D Convolution Engine with DMA
 *
 * Computes output[r][c] = sum(kernel[i][j] * input[r+i][c+j]) for each (r,c).
 * K=3 (3×3) is the only implemented kernel size; KERNEL_SIZE CSR is readable
 * but the FSM always uses K=3 offsets.
 *
 * Padding modes:
 *   Valid (PADDING_MODE=0): output (H−2)×(W−2); no zero-padding.
 *   Same  (PADDING_MODE=1): output H×W; zero-pad at all borders.
 *
 * Memory: each INT8 pixel in one 32-bit word (bits [7:0]); outputs are INT32.
 *
 * Register map (offsets from base):
 *   0x00 CTRL         W    [0]=GO, [1]=SOFT_RESET, [2]=STREAM_MODE
 *   0x04 STATUS       R    [0]=BUSY, [1]=DONE
 *   0x08 SRC_ADDR    R/W
 *   0x0C DST_ADDR    R/W   (unused in stream mode)
 *   0x10 (reserved)
 *   0x14 IER         R/W   [0] IRQ enable
 *   0x18 IMG_WIDTH   R/W   ≤ 64
 *   0x1C IMG_HEIGHT  R/W   ≤ 64
 *   0x20 KERNEL_SIZE R/W   always 3 in practice
 *   0x24 PADDING_MODE R/W  [0] zero-pad enable
 *   0x28–0x48 KERNEL_W[0..8] R/W  INT8 weights, row-major top-left→bottom-right
 *
 * Stream mode (CTRL[2]=1):
 *   Reads input from DMA as normal, but instead of writing results back to
 *   DRAM, outputs each result via AXI-Stream (m_axis_*). DST_ADDR is unused.
 */
module conv2d (
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
  // Constants
  // -------------------------------------------------------------------------
  localparam int unsigned MAX_IMG_WIDTH = 64;

  localparam logic [9:0] REG_CTRL         = 10'h000;
  localparam logic [9:0] REG_STATUS       = 10'h004;
  localparam logic [9:0] REG_SRC_ADDR    = 10'h008;
  localparam logic [9:0] REG_DST_ADDR    = 10'h00C;
  localparam logic [9:0] REG_IER         = 10'h014;
  localparam logic [9:0] REG_IMG_WIDTH   = 10'h018;
  localparam logic [9:0] REG_IMG_HEIGHT  = 10'h01C;
  localparam logic [9:0] REG_KERNEL_SIZE = 10'h020;
  localparam logic [9:0] REG_PAD_MODE    = 10'h024;
  // KERNEL_W[n] at 0x028 + n*4  (n = 0..8)

  // -------------------------------------------------------------------------
  // Configuration registers
  // -------------------------------------------------------------------------
  logic [31:0]       src_addr_q, dst_addr_q;
  logic              ier_done_q;
  logic              stream_mode_q;  // 0=DMA write, 1=AXI-Stream output
  logic [31:0]       img_width_q, img_height_q;
  logic [31:0]       kernel_size_q;
  logic              zero_pad_q;
  logic signed [7:0] kernel_w_q [9];

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------
  logic busy_q, done_q;

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    FILL_RD_REQ,
    FILL_RD_WAIT,
    SLIDE_RD_REQ,
    SLIDE_RD_WAIT,
    SLIDE_WR_REQ,
    SLIDE_WR_WAIT,
    STREAM_OUT
  } state_e;
  state_e state_q, state_d;

  // -------------------------------------------------------------------------
  // Working registers
  // -------------------------------------------------------------------------
  logic [31:0]       fill_row_q, fill_col_q;   // FILL phase position
  logic [31:0]       cur_row_q, cur_col_q;     // SLIDE phase position
  logic [31:0]       lag_q;                    // K/2 (same) or K-1 (valid)
  logic [31:0]       col_end_q;               // last SLIDE col (inclusive)
  logic [31:0]       row_end_q;               // last SLIDE row (inclusive)
  logic [31:0]       wr_remaining_q;          // output pixels yet to write
  logic [31:0]       cur_dst_q;              // current output DMA address
  logic signed [31:0] pe_result_q;            // captured PE result
  logic              skip_dma_q;             // 1 = virtual pixel, no DMA

  // -------------------------------------------------------------------------
  // Combinational GO / SOFT_RESET decode
  // -------------------------------------------------------------------------
  logic go, soft_reset;
  assign go         = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
                      & ctrl_wdata_i[0] & ~busy_q;
  assign soft_reset = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
                      & ctrl_wdata_i[1];

  assign irq_o  = done_q & ier_done_q;
  assign dma_be_o = 4'b1111;

  // AXI-Stream output: driven from STREAM_OUT state
  assign m_axis_tvalid_o = (state_q == STREAM_OUT);
  assign m_axis_tdata_o  = pe_result_q;
  assign m_axis_tlast_o  = (state_q == STREAM_OUT) & (wr_remaining_q == 32'd1);

  // -------------------------------------------------------------------------
  // At-GO combinational: derived counts
  // -------------------------------------------------------------------------
  logic [31:0] lag_next, col_end_next, row_end_next, wr_total_next;
  logic [31:0] out_h_next, out_w_next;

  assign lag_next     = zero_pad_q ? (kernel_size_q >> 1) : (kernel_size_q - 32'd1);
  assign col_end_next = zero_pad_q ? img_width_q  : (img_width_q  - 32'd1);
  assign row_end_next = zero_pad_q ? img_height_q : (img_height_q - 32'd1);
  assign out_h_next   = zero_pad_q ? img_height_q : (img_height_q - kernel_size_q + 32'd1);
  assign out_w_next   = zero_pad_q ? img_width_q  : (img_width_q  - kernel_size_q + 32'd1);
  assign wr_total_next = out_h_next * out_w_next;

  // -------------------------------------------------------------------------
  // Line buffer
  // -------------------------------------------------------------------------
  logic signed [7:0] lb_pixels [3][MAX_IMG_WIDTH];
  logic              lb_wr_en;
  logic [1:0]        lb_wr_row;
  logic [5:0]        lb_wr_col;
  logic signed [7:0] lb_wr_data;

  line_buffer #(.MAX_WIDTH(MAX_IMG_WIDTH)) u_line_buffer (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .clr_i    (soft_reset),
    .wr_en_i  (lb_wr_en),
    .wr_row_i (lb_wr_row),
    .wr_col_i (lb_wr_col),
    .wr_data_i(lb_wr_data),
    .pixels_o (lb_pixels)
  );

  // -------------------------------------------------------------------------
  // Address generator (used for DMA reads in both FILL and SLIDE)
  // -------------------------------------------------------------------------
  logic [31:0] rd_row_mux, rd_col_mux, rd_addr;
  assign rd_row_mux = ((state_q == FILL_RD_REQ) || (state_q == FILL_RD_WAIT))
                      ? fill_row_q : cur_row_q;
  assign rd_col_mux = ((state_q == FILL_RD_REQ) || (state_q == FILL_RD_WAIT))
                      ? fill_col_q : cur_col_q;

  addr_gen u_addr_gen (
    .src_addr_i  (src_addr_q),
    .img_width_i (img_width_q),
    .cur_row_i   (rd_row_mux),
    .cur_col_i   (rd_col_mux),
    .rd_addr_o   (rd_addr)
  );

  // -------------------------------------------------------------------------
  // Window extraction (combinational, uses lb_pixels)
  // -------------------------------------------------------------------------
  logic signed [7:0] window [3][3];
  logic [1:0]        lb_oldest_sel, lb_middle_sel, lb_newest_sel;

  assign lb_oldest_sel = 2'(unsigned'((cur_row_q + 32'd1) % 32'd3));
  assign lb_middle_sel = 2'(unsigned'((cur_row_q + 32'd2) % 32'd3));
  assign lb_newest_sel = 2'(unsigned'(cur_row_q % 32'd3));

  always_comb begin
    for (int r = 0; r < 3; r++) begin
      automatic logic [1:0] lb_sel;
      automatic int         col_base;
      case (r)
        0:       lb_sel = lb_oldest_sel;
        1:       lb_sel = lb_middle_sel;
        default: lb_sel = lb_newest_sel;
      endcase
      col_base = int'(cur_col_q) - 2;  // left edge of 3-col window
      for (int c = 0; c < 3; c++) begin
        automatic int col_idx;
        col_idx = col_base + c;
        // Zero for: virtual bottom row (same mode), left out-of-bounds
        if ((r == 2) && zero_pad_q && (cur_row_q >= img_height_q)) begin
          window[r][c] = 8'sh0;
        end else if (col_idx < 0) begin
          window[r][c] = 8'sh0;
        end else if (lb_wr_en && (lb_wr_row == lb_sel) && (lb_wr_col == col_idx[5:0])) begin
          window[r][c] = lb_wr_data;  // write-through: bypass registered LB for current pixel
        end else begin
          window[r][c] = lb_pixels[lb_sel][col_idx[5:0]];
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // PE (combinational)
  // -------------------------------------------------------------------------
  logic signed [31:0] pe_result_comb;

  conv2d_pe u_pe (
    .window_i  (window),
    .weights_i (kernel_w_q),
    .result_o  (pe_result_comb)
  );

  // output produced when column window is fully within the lag
  logic should_output;
  assign should_output = (cur_col_q >= lag_q);

  // -------------------------------------------------------------------------
  // Line-buffer write signals (combinational, driven by FSM states)
  // -------------------------------------------------------------------------
  // Written from FILL_RD_WAIT and SLIDE_RD_WAIT when not virtual
  // See sequential block for actual assignments

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
          REG_CTRL:         ctrl_rdata_o <= 32'd0;
          REG_STATUS:       ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_SRC_ADDR:     ctrl_rdata_o <= src_addr_q;
          REG_DST_ADDR:     ctrl_rdata_o <= dst_addr_q;
          REG_IER:          ctrl_rdata_o <= {31'd0, ier_done_q};
          REG_IMG_WIDTH:    ctrl_rdata_o <= img_width_q;
          REG_IMG_HEIGHT:   ctrl_rdata_o <= img_height_q;
          REG_KERNEL_SIZE:  ctrl_rdata_o <= kernel_size_q;
          REG_PAD_MODE:     ctrl_rdata_o <= {31'd0, zero_pad_q};
          default: begin
            if (ctrl_addr_i[9:0] >= 10'h028 && ctrl_addr_i[9:0] <= 10'h048) begin
              automatic int unsigned widx;
              widx = (32'(ctrl_addr_i[9:2]) - 32'h0A);  // (offset/4) - 10
              if (widx < 9)
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
      ier_done_q    <= 1'b0;
      stream_mode_q <= 1'b0;
      img_width_q   <= 32'd8;
      img_height_q  <= 32'd8;
      kernel_size_q <= 32'd3;
      zero_pad_q    <= 1'b0;
      for (int i = 0; i < 9; i++) kernel_w_q[i] <= '0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_SRC_ADDR:   src_addr_q    <= ctrl_wdata_i;
        REG_DST_ADDR:   dst_addr_q    <= ctrl_wdata_i;
        REG_IER:        ier_done_q    <= ctrl_wdata_i[0];
        REG_CTRL:       stream_mode_q <= ctrl_wdata_i[2];
        REG_IMG_WIDTH:  img_width_q   <= ctrl_wdata_i;
        REG_IMG_HEIGHT: img_height_q  <= ctrl_wdata_i;
        REG_KERNEL_SIZE: kernel_size_q <= ctrl_wdata_i;
        REG_PAD_MODE:   zero_pad_q    <= ctrl_wdata_i[0];
        default: begin
          if (ctrl_addr_i[9:0] >= 10'h028 && ctrl_addr_i[9:0] <= 10'h048) begin
            automatic int unsigned widx;
            widx = (32'(ctrl_addr_i[9:2]) - 32'h0A);
            if (widx < 9)
              kernel_w_q[widx] <= signed'(ctrl_wdata_i[7:0]);
          end
        end
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // FSM — combinational next-state and DMA output signals
  // -------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;
    lb_wr_en    = 1'b0;
    lb_wr_row   = 2'd0;
    lb_wr_col   = 6'd0;
    lb_wr_data  = 8'sh0;

    case (state_q)
      IDLE: begin
        if (go) state_d = FILL_RD_REQ;
      end

      FILL_RD_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = rd_addr;
        if (dma_gnt_i) state_d = FILL_RD_WAIT;
      end

      FILL_RD_WAIT: begin
        if (dma_rvalid_i) begin
          // Write pixel to line buffer
          lb_wr_en   = 1'b1;
          lb_wr_row  = 2'(unsigned'(fill_row_q % 32'd3));
          lb_wr_col  = fill_col_q[5:0];
          lb_wr_data = signed'(dma_rdata_i[7:0]);
          // Advance position
          if (fill_col_q < img_width_q - 32'd1) begin
            state_d = FILL_RD_REQ;  // more cols in this fill row
          end else begin
            // End of fill row
            if (fill_row_q + 32'd1 < lag_q) begin
              state_d = FILL_RD_REQ;  // more fill rows
            end else begin
              state_d = SLIDE_RD_REQ; // FILL complete
            end
          end
        end
      end

      SLIDE_RD_REQ: begin
        // is_virtual: no DMA needed for this position
        if (skip_dma_q) begin
          // Virtual pixel: go directly to SLIDE_RD_WAIT (which exits immediately)
          state_d = SLIDE_RD_WAIT;
        end else begin
          dma_req_o  = 1'b1;
          dma_addr_o = rd_addr;
          if (dma_gnt_i) state_d = SLIDE_RD_WAIT;
        end
      end

      SLIDE_RD_WAIT: begin
        if (skip_dma_q || dma_rvalid_i) begin
          // Write to line buffer if not virtual
          if (!skip_dma_q) begin
            lb_wr_en   = 1'b1;
            lb_wr_row  = 2'(unsigned'(cur_row_q % 32'd3));
            lb_wr_col  = cur_col_q[5:0];
            lb_wr_data = signed'(dma_rdata_i[7:0]);
          end
          // Decide next: write output or advance
          if (should_output) begin
            state_d = SLIDE_WR_REQ;
          end else begin
            // No output at this col; advance position
            if (cur_col_q < col_end_q) begin
              state_d = SLIDE_RD_REQ;
            end else if (cur_row_q < row_end_q) begin
              state_d = SLIDE_RD_REQ;  // new row; sequential block resets cur_col
            end else begin
              state_d = IDLE;  // should not happen: wr_remaining guards this
            end
          end
        end
      end

      SLIDE_WR_REQ: begin
        if (stream_mode_q) begin
          // In stream mode go directly to STREAM_OUT (skip DMA write)
          state_d = STREAM_OUT;
        end else begin
          dma_req_o   = 1'b1;
          dma_addr_o  = cur_dst_q;
          dma_we_o    = 1'b1;
          dma_wdata_o = pe_result_q;
          if (dma_gnt_i) state_d = SLIDE_WR_WAIT;
        end
      end

      SLIDE_WR_WAIT: begin
        if (dma_rvalid_i) begin
          if (wr_remaining_q == 32'd1) begin
            state_d = IDLE;  // last output written
          end else if (cur_col_q < col_end_q) begin
            state_d = SLIDE_RD_REQ;
          end else if (cur_row_q < row_end_q) begin
            state_d = SLIDE_RD_REQ;  // sequential block handles row advance
          end else begin
            state_d = IDLE;
          end
        end
      end

      STREAM_OUT: begin
        // Wait for downstream consumer to accept the beat
        if (m_axis_tready_i) begin
          if (wr_remaining_q == 32'd1) begin
            state_d = IDLE;
          end else if (cur_col_q < col_end_q) begin
            state_d = SLIDE_RD_REQ;
          end else if (cur_row_q < row_end_q) begin
            state_d = SLIDE_RD_REQ;
          end else begin
            state_d = IDLE;
          end
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // FSM — sequential state and working registers
  // -------------------------------------------------------------------------
  // is_virtual: combinational for skip_dma_q logic

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= IDLE;
      busy_q         <= 1'b0;
      done_q         <= 1'b0;
      fill_row_q     <= 32'd0;
      fill_col_q     <= 32'd0;
      cur_row_q      <= 32'd0;
      cur_col_q      <= 32'd0;
      lag_q          <= 32'd2;
      col_end_q      <= 32'd0;
      row_end_q      <= 32'd0;
      wr_remaining_q <= 32'd0;
      cur_dst_q      <= 32'd0;
      pe_result_q    <= 32'sd0;
      skip_dma_q     <= 1'b0;
    end else begin
      state_q <= state_d;

      if (soft_reset) begin
        busy_q         <= 1'b0;
        done_q         <= 1'b0;
        wr_remaining_q <= 32'd0;
      end

      case (state_q)
        IDLE: begin
          if (go) begin
            busy_q         <= 1'b1;
            done_q         <= 1'b0;
            fill_row_q     <= 32'd0;
            fill_col_q     <= 32'd0;
            lag_q          <= lag_next;
            col_end_q      <= col_end_next;
            row_end_q      <= row_end_next;
            wr_remaining_q <= wr_total_next;
            cur_dst_q      <= dst_addr_q;
            // skip_dma_q for first SLIDE position (col 0 is never virtual)
            skip_dma_q     <= 1'b0;
          end
        end

        FILL_RD_WAIT: begin
          if (dma_rvalid_i) begin
            if (fill_col_q < img_width_q - 32'd1) begin
              fill_col_q <= fill_col_q + 32'd1;
            end else begin
              fill_col_q <= 32'd0;
              fill_row_q <= fill_row_q + 32'd1;
              if (fill_row_q + 32'd1 >= lag_q) begin
                // Transition to SLIDE: initialize slide position
                cur_row_q  <= lag_q;
                cur_col_q  <= 32'd0;
                skip_dma_q <= 1'b0;  // first SLIDE position is always real
              end
            end
          end
        end

        SLIDE_RD_WAIT: begin
          if (skip_dma_q || dma_rvalid_i) begin
            // Capture PE result if we're about to write
            if (should_output) begin
              pe_result_q <= pe_result_comb;
            end
            // Advance position (if not going to write output)
            if (!should_output) begin
              if (cur_col_q < col_end_q) begin
                cur_col_q  <= cur_col_q + 32'd1;
                skip_dma_q <= zero_pad_q & (cur_col_q + 32'd1 >= img_width_q);
              end else begin
                cur_col_q  <= 32'd0;
                cur_row_q  <= cur_row_q + 32'd1;
                skip_dma_q <= 1'b0;  // col 0 of new row is always real
              end
            end
            // If should_output: position is advanced in SLIDE_WR_WAIT
          end
        end

        SLIDE_WR_WAIT: begin
          if (dma_rvalid_i) begin
            wr_remaining_q <= wr_remaining_q - 32'd1;
            cur_dst_q      <= cur_dst_q + 32'd4;
            if (wr_remaining_q != 32'd1) begin
              // Advance position for next read
              if (cur_col_q < col_end_q) begin
                cur_col_q  <= cur_col_q + 32'd1;
                skip_dma_q <= zero_pad_q & (cur_col_q + 32'd1 >= img_width_q);
              end else begin
                cur_col_q  <= 32'd0;
                cur_row_q  <= cur_row_q + 32'd1;
                skip_dma_q <= 1'b0;
              end
            end else begin
              // Last write: go IDLE
              busy_q <= 1'b0;
              done_q <= 1'b1;
            end
          end
        end

        STREAM_OUT: begin
          if (m_axis_tready_i) begin
            wr_remaining_q <= wr_remaining_q - 32'd1;
            if (wr_remaining_q != 32'd1) begin
              if (cur_col_q < col_end_q) begin
                cur_col_q  <= cur_col_q + 32'd1;
                skip_dma_q <= zero_pad_q & (cur_col_q + 32'd1 >= img_width_q);
              end else begin
                cur_col_q  <= 32'd0;
                cur_row_q  <= cur_row_q + 32'd1;
                skip_dma_q <= 1'b0;
              end
            end else begin
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

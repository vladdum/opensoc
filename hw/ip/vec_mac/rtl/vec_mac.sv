// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Vector MAC Accelerator with DMA
 *
 * Computes the dot product of two INT8 vectors in memory:
 *   result = dot(A[N], B[N]) -> saturating INT32
 *
 * The DMA engine time-multiplexes reads of vectors A and B through a single
 * master port, feeding a parallel MAC array (vec_mac_core). The scalar result
 * is written back to a destination address on completion.
 *
 * Control registers (offset from base):
 *   0x00  SRC_A_ADDR - Vector A source address (R/W)
 *   0x04  SRC_B_ADDR - Vector B source address (R/W)
 *   0x08  DST_ADDR   - Result destination address (R/W)
 *   0x0C  LEN        - Number of INT8 elements per vector (R/W)
 *   0x10  CTRL       - [0] GO, [1] NO_ACCUM_CLEAR (W, sampled on GO)
 *   0x14  STATUS     - [0] BUSY, [1] DONE (R)
 *   0x18  IER        - [0] Done interrupt enable (R/W)
 *   0x1C  RESULT     - Accumulator value (R)
 *
 * LEN must be a multiple of NUM_LANES. Hardware masks off low bits.
 * GO while BUSY is silently ignored.
 */
module vec_mac #(
  parameter int unsigned NUM_LANES = 4
) (
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

  // Interrupt
  output logic        irq_o
);

  // ---------------------------------------------------------------------------
  // Register offsets (10-bit, matching 1 kB address window)
  // ---------------------------------------------------------------------------
  localparam logic [9:0] REG_SRC_A_ADDR = 10'h000;
  localparam logic [9:0] REG_SRC_B_ADDR = 10'h004;
  localparam logic [9:0] REG_DST_ADDR   = 10'h008;
  localparam logic [9:0] REG_LEN        = 10'h00C;
  localparam logic [9:0] REG_CTRL       = 10'h010;
  localparam logic [9:0] REG_STATUS     = 10'h014;
  localparam logic [9:0] REG_IER        = 10'h018;
  localparam logic [9:0] REG_RESULT     = 10'h01C;

  // Bits per lane (for LEN -> word count conversion)
  localparam int unsigned LOG2_LANES = $clog2(NUM_LANES);

  // ---------------------------------------------------------------------------
  // Configuration registers
  // ---------------------------------------------------------------------------
  logic [31:0] src_a_addr_q, src_b_addr_q, dst_addr_q, len_q;
  logic        ier_done_q;

  // ---------------------------------------------------------------------------
  // Status flags
  // ---------------------------------------------------------------------------
  logic busy_q, done_q;

  // ---------------------------------------------------------------------------
  // DMA working state
  // ---------------------------------------------------------------------------
  logic [31:0] cur_src_a_q, cur_src_b_q, cur_dst_q;
  logic [31:0] remaining_q;  // remaining words (not elements)
  logic [31:0] a_data_q;     // latched A word from DMA read
  logic [31:0] b_data_q;     // latched B word from DMA read

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    RD_A_REQ,
    RD_A_WAIT,
    RD_B_REQ,
    RD_B_WAIT,
    WR_REQ,
    WR_WAIT
  } state_e;

  state_e state_q, state_d;

  // GO pulse: valid only when not busy
  logic go;
  assign go = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
              & ctrl_wdata_i[0] & ~busy_q;

  // NO_ACCUM_CLEAR: sampled from CTRL[1] on GO (transient)
  logic no_accum_clear_q;

  // MAC core interface
  logic        mac_clear;
  logic        mac_valid;
  logic [31:0] mac_result;

  // Interrupt output: level-sensitive
  assign irq_o = done_q & ier_done_q;

  // DMA byte enables: always full-word
  assign dma_be_o = 4'b1111;

  // Number of words from LEN (mask off low bits, shift right by LOG2_LANES)
  // Then multiply by 1 since each word = NUM_LANES elements
  // For NUM_LANES=4: len_words = len_q >> 2 (drop low 2 bits)
  logic [31:0] len_words;
  assign len_words = len_q >> LOG2_LANES;

  // ---------------------------------------------------------------------------
  // MAC compute core
  // ---------------------------------------------------------------------------
  vec_mac_core #(
    .NUM_LANES (NUM_LANES)
  ) u_mac_core (
    .clk_i,
    .rst_ni,
    .clear_i  (mac_clear),
    .valid_i  (mac_valid),
    .a_data_i (a_data_q),
    .b_data_i (b_data_q),
    .result_o (mac_result)
  );

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
          REG_SRC_A_ADDR: ctrl_rdata_o <= src_a_addr_q;
          REG_SRC_B_ADDR: ctrl_rdata_o <= src_b_addr_q;
          REG_DST_ADDR:   ctrl_rdata_o <= dst_addr_q;
          REG_LEN:        ctrl_rdata_o <= len_q;
          REG_CTRL:       ctrl_rdata_o <= 32'd0;
          REG_STATUS:     ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_IER:        ctrl_rdata_o <= {31'd0, ier_done_q};
          REG_RESULT:     ctrl_rdata_o <= mac_result;
          default:        ctrl_rdata_o <= 32'd0;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Control register write path
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_a_addr_q <= 32'd0;
      src_b_addr_q <= 32'd0;
      dst_addr_q   <= 32'd0;
      len_q        <= 32'd0;
      ier_done_q   <= 1'b0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_SRC_A_ADDR: src_a_addr_q <= ctrl_wdata_i;
        REG_SRC_B_ADDR: src_b_addr_q <= ctrl_wdata_i;
        REG_DST_ADDR:   dst_addr_q   <= ctrl_wdata_i;
        REG_LEN:        len_q        <= ctrl_wdata_i;
        REG_IER:        ier_done_q   <= ctrl_wdata_i[0];
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
    mac_clear   = 1'b0;
    mac_valid   = 1'b0;

    case (state_q)
      IDLE: begin
        if (go) begin
          // Clear accumulator unless NO_ACCUM_CLEAR is set
          if (!ctrl_wdata_i[1]) mac_clear = 1'b1;
          if (len_words != 32'd0) begin
            state_d = RD_A_REQ;
          end
          // LEN=0: stay in IDLE, done_q set in sequential block
        end
      end

      RD_A_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = cur_src_a_q;
        if (dma_gnt_i) state_d = RD_A_WAIT;
      end

      RD_A_WAIT: begin
        if (dma_rvalid_i) state_d = RD_B_REQ;
      end

      RD_B_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = cur_src_b_q;
        if (dma_gnt_i) state_d = RD_B_WAIT;
      end

      RD_B_WAIT: begin
        if (dma_rvalid_i) begin
          // Trigger MAC accumulate (data latched in sequential block)
          mac_valid = 1'b1;
          if (remaining_q == 32'd1) begin
            state_d = WR_REQ;
          end else begin
            state_d = RD_A_REQ;
          end
        end
      end

      WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = cur_dst_q;
        dma_we_o    = 1'b1;
        dma_wdata_o = mac_result;
        if (dma_gnt_i) state_d = WR_WAIT;
      end

      WR_WAIT: begin
        if (dma_rvalid_i) state_d = IDLE;
      end

      default: state_d = IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — sequential state and working registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= IDLE;
      busy_q           <= 1'b0;
      done_q           <= 1'b0;
      no_accum_clear_q <= 1'b0;
      cur_src_a_q      <= 32'd0;
      cur_src_b_q      <= 32'd0;
      cur_dst_q        <= 32'd0;
      remaining_q      <= 32'd0;
      a_data_q         <= 32'd0;
      b_data_q         <= 32'd0;
    end else begin
      state_q <= state_d;

      case (state_q)
        IDLE: begin
          if (go) begin
            done_q           <= 1'b0;
            no_accum_clear_q <= ctrl_wdata_i[1];
            cur_src_a_q      <= src_a_addr_q;
            cur_src_b_q      <= src_b_addr_q;
            cur_dst_q        <= dst_addr_q;
            remaining_q      <= len_words;
            if (len_words != 32'd0) begin
              busy_q <= 1'b1;
            end else begin
              // LEN=0: immediately done
              done_q <= 1'b1;
            end
          end
        end

        RD_A_WAIT: begin
          if (dma_rvalid_i) begin
            a_data_q <= dma_rdata_i;
          end
        end

        RD_B_WAIT: begin
          if (dma_rvalid_i) begin
            b_data_q    <= dma_rdata_i;
            // Address and counter update
            cur_src_a_q <= cur_src_a_q + 32'd4;
            cur_src_b_q <= cur_src_b_q + 32'd4;
            remaining_q <= remaining_q - 32'd1;
          end
        end

        WR_WAIT: begin
          if (dma_rvalid_i) begin
            busy_q <= 1'b0;
            done_q <= 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

endmodule

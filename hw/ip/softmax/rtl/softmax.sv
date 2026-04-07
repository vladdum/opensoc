// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Softmax Pipeline Accelerator
 *
 * Three-pass streaming pipeline computing softmax over INT8 vectors using
 * LUT-based exp() approximation and fixed-point arithmetic.
 *
 *   Pass 1 (DMA Read + Max): Read input from DRAM into internal buffer,
 *          find max INT8 value.
 *   Pass 2 (Exp + Sum): For each element compute exp(x - max) via LUT,
 *          accumulate sum, overwrite buffer in-place.
 *   Pass 3 (Normalize + DMA Write): Compute reciprocal of sum once, then
 *          normalize each element, pack 4 UINT8 results per word, DMA write.
 *
 * Control registers (offset from base):
 *   0x00  CTRL       - [0] GO (W), [1] STREAM_IN: 1=accept input from AXI-Stream
 *   0x04  STATUS     - [0] BUSY, [1] DONE (R)
 *   0x08  SRC_ADDR   - Input vector base address (R/W, unused in stream mode)
 *   0x0C  DST_ADDR   - Output vector base address (R/W)
 *   0x10  VEC_LEN    - Number of INT8 elements, 1-256, multiple of 4 (R/W)
 *   0x14  IER        - [0] Done interrupt enable (R/W)
 *   0x18  MAX_VAL    - Debug: max value found in Pass 1 (sign-extended, R)
 *   0x1C  SUM_VAL    - Debug: sum of exp values from Pass 2 (R)
 *
 * GO while BUSY is silently ignored.
 * VEC_LEN must be a multiple of 4. VEC_LEN=0 produces immediate DONE.
 *
 * Stream input mode (CTRL[1]=1):
 *   Replaces Phase 1 DMA reads with AXI-Stream. Each 32-bit beat carries one
 *   INT8 element in bits [7:0]. VEC_LEN beats are consumed. SRC_ADDR unused.
 */
module softmax #(
  parameter int unsigned MaxVecLen = 256
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

  // AXI-Stream input (stream mode only, ignored in DMA mode)
  input  logic        s_axis_tvalid_i,
  output logic        s_axis_tready_o,
  input  logic [31:0] s_axis_tdata_i,
  input  logic        s_axis_tlast_i,

  // Interrupt
  output logic        irq_o
);

  // ---------------------------------------------------------------------------
  // Register offsets (10-bit, matching 1 kB address window)
  // ---------------------------------------------------------------------------
  localparam logic [9:0] REG_CTRL     = 10'h000;
  localparam logic [9:0] REG_STATUS   = 10'h004;
  localparam logic [9:0] REG_SRC_ADDR = 10'h008;
  localparam logic [9:0] REG_DST_ADDR = 10'h00C;
  localparam logic [9:0] REG_VEC_LEN  = 10'h010;
  localparam logic [9:0] REG_IER      = 10'h014;
  localparam logic [9:0] REG_MAX_VAL  = 10'h018;
  localparam logic [9:0] REG_SUM_VAL  = 10'h01C;

  // ---------------------------------------------------------------------------
  // Configuration registers
  // ---------------------------------------------------------------------------
  logic [31:0] src_addr_q, dst_addr_q;
  logic [31:0] vec_len_q;
  logic        ier_done_q;
  logic        stream_mode_q;    // 0=DMA input, 1=AXI-Stream input
  logic [31:0] p1_stream_idx_q;  // element index for stream Phase 1

  // ---------------------------------------------------------------------------
  // Status flags
  // ---------------------------------------------------------------------------
  logic busy_q, done_q;

  // ---------------------------------------------------------------------------
  // Internal buffer (256 × 8-bit)
  // ---------------------------------------------------------------------------
  logic [7:0] buffer [MaxVecLen];

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    IDLE,
    P1_RD_REQ,
    P1_RD_WAIT,
    P1_STREAM,
    P2_COMPUTE,
    P2_RECIP,
    P3_NORM,
    P3_WR_REQ,
    P3_WR_WAIT,
    DONE_STATE
  } state_e;

  state_e state_q, state_d;

  // GO pulse: valid only when not busy
  logic go;
  assign go = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
              & ctrl_wdata_i[0] & ~busy_q;

  // Interrupt: level-sensitive
  assign irq_o = done_q & ier_done_q;

  // DMA byte enables: always full-word
  assign dma_be_o = 4'b1111;

  // AXI-Stream slave: accept beats only during P1_STREAM
  assign s_axis_tready_o = (state_q == P1_STREAM);

  // ---------------------------------------------------------------------------
  // Phase 1 working registers
  // ---------------------------------------------------------------------------
  logic [31:0] p1_offset_q;       // byte offset for DMA reads (0, 4, 8, ...)
  logic [31:0] p1_elem_base_q;    // element index base for buffer writes
  logic signed [7:0] max_val_q;   // running max (signed INT8)

  // Phase 1 max update (combinational) — DMA path: 4 elements per word
  logic signed [7:0] p1_new_max;
  always_comb begin
    p1_new_max = max_val_q;
    if ($signed(dma_rdata_i[7:0])   > p1_new_max) p1_new_max = $signed(dma_rdata_i[7:0]);
    if ($signed(dma_rdata_i[15:8])  > p1_new_max) p1_new_max = $signed(dma_rdata_i[15:8]);
    if ($signed(dma_rdata_i[23:16]) > p1_new_max) p1_new_max = $signed(dma_rdata_i[23:16]);
    if ($signed(dma_rdata_i[31:24]) > p1_new_max) p1_new_max = $signed(dma_rdata_i[31:24]);
  end

  // Phase 1 max update — stream path: 1 element per beat (bits [7:0])
  logic signed [7:0] p1_stream_new_max;
  assign p1_stream_new_max = ($signed(s_axis_tdata_i[7:0]) > $signed(max_val_q))
                             ? $signed(s_axis_tdata_i[7:0]) : max_val_q;

  // ---------------------------------------------------------------------------
  // Phase 2 working registers
  // ---------------------------------------------------------------------------
  logic [31:0] p2_idx_q;          // element index (0 to vec_len-1)
  logic [23:0] sum_q;             // running sum of exp values

  // Phase 2 diff computation (combinational): max - buffer[idx], 0..255
  logic [7:0] p2_buf_val;
  logic [8:0] p2_diff;
  assign p2_buf_val = buffer[p2_idx_q[$clog2(MaxVecLen)-1:0]];
  assign p2_diff = {max_val_q[7], max_val_q} - {p2_buf_val[7], p2_buf_val};

  // ---------------------------------------------------------------------------
  // Sequential divider registers (Phase 2 → 3 transition)
  // ---------------------------------------------------------------------------
  // Computes recip = 65536 / sum using restoring division (17 cycles)
  logic [16:0] div_rem_q;
  logic [16:0] div_quot_q;
  logic [4:0]  div_bit_q;         // current bit position (16 downto 0)

  // Dividend bit: 65536 = 1 << 16, so only bit 16 is set
  logic div_dividend_bit;
  assign div_dividend_bit = (div_bit_q == 5'd16);

  // Trial remainder for divider
  logic [16:0] div_new_rem;
  assign div_new_rem = {div_rem_q[15:0], div_dividend_bit};

  // Divisor for comparison (sum, max 65280 = 16 bits)
  logic [16:0] div_sum_ext;
  assign div_sum_ext = {1'b0, sum_q[15:0]};

  // Registered decode of P2_COMPUTE — avoids high-fanout net from state logic
  // gate to all buffer write-enables. p2_compute_q is in phase with state_q
  // (both register state_d at the same clock edge) but is driven from a FF Q
  // output instead of a small AND gate, eliminating the ~42 ns fanout delay.
  logic p2_compute_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) p2_compute_q <= 1'b0;
    else         p2_compute_q <= (state_d == P2_COMPUTE);
  end

  // ---------------------------------------------------------------------------
  // Phase 3 working registers
  // ---------------------------------------------------------------------------
  logic [31:0] p3_idx_q;          // element index
  logic [1:0]  p3_pack_q;         // byte packing counter (0..3)
  logic [31:0] p3_word_q;         // accumulating packed output word
  logic [31:0] p3_offset_q;       // byte offset for DMA writes

  // ---------------------------------------------------------------------------
  // Softmax compute core
  // ---------------------------------------------------------------------------
  logic [7:0] core_exp_val;       // Phase 2 exp lookup result
  logic [7:0] core_norm_out;      // Phase 3 normalized output

  softmax_core u_core (
    .exp_index_i  (p2_diff[7:0]),
    .exp_val_o    (core_exp_val),
    .norm_exp_i   (buffer[p3_idx_q[$clog2(MaxVecLen)-1:0]]),
    .norm_recip_i (div_quot_q),
    .norm_out_o   (core_norm_out)
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
          REG_CTRL:     ctrl_rdata_o <= 32'd0;
          REG_STATUS:   ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_SRC_ADDR: ctrl_rdata_o <= src_addr_q;
          REG_DST_ADDR: ctrl_rdata_o <= dst_addr_q;
          REG_VEC_LEN:  ctrl_rdata_o <= vec_len_q;
          REG_IER:      ctrl_rdata_o <= {31'd0, ier_done_q};
          REG_MAX_VAL:  ctrl_rdata_o <= {{24{max_val_q[7]}}, max_val_q};
          REG_SUM_VAL:  ctrl_rdata_o <= {8'd0, sum_q};
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
      src_addr_q    <= 32'd0;
      dst_addr_q    <= 32'd0;
      vec_len_q     <= 32'd0;
      ier_done_q    <= 1'b0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_SRC_ADDR: src_addr_q <= ctrl_wdata_i;
        REG_DST_ADDR: dst_addr_q <= ctrl_wdata_i;
        REG_VEC_LEN:  vec_len_q  <= ctrl_wdata_i;
        REG_IER:      ier_done_q <= ctrl_wdata_i[0];
        default: ;
      endcase
    end
    // stream_mode_q latched in the IDLE sequential block when GO fires
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — next-state and output logic (combinational)
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;

    case (state_q)
      IDLE: begin
        if (go && vec_len_q != 32'd0) begin
          state_d = ctrl_wdata_i[1] ? P1_STREAM : P1_RD_REQ;
        end
        // VEC_LEN=0: done_q set in sequential block, stay IDLE
      end

      // -- Phase 1: Stream Read + Max Find (one element per beat) --
      P1_STREAM: begin
        if (s_axis_tvalid_i && (p1_stream_idx_q + 32'd1 >= vec_len_q))
          state_d = P2_COMPUTE;
        // else: stay in P1_STREAM
      end

      // -- Phase 1: DMA Read + Max Find --
      P1_RD_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = src_addr_q + p1_offset_q;
        if (dma_gnt_i) state_d = P1_RD_WAIT;
      end

      P1_RD_WAIT: begin
        if (dma_rvalid_i) begin
          if (p1_elem_base_q + 32'd4 >= vec_len_q)
            state_d = P2_COMPUTE;
          else
            state_d = P1_RD_REQ;
        end
      end

      // -- Phase 2: Exp + Sum (internal, 1 element/cycle) --
      P2_COMPUTE: begin
        if (p2_idx_q >= vec_len_q - 32'd1)
          state_d = P2_RECIP;
        // else: stay in P2_COMPUTE
      end

      // -- Phase 2→3: Sequential divider (17 cycles) --
      P2_RECIP: begin
        if (div_bit_q == 5'd0)
          state_d = P3_NORM;
      end

      // -- Phase 3: Normalize + pack bytes --
      P3_NORM: begin
        if (p3_pack_q == 2'd3)
          state_d = P3_WR_REQ;
      end

      P3_WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = dst_addr_q + p3_offset_q;
        dma_we_o    = 1'b1;
        dma_wdata_o = p3_word_q;
        if (dma_gnt_i) state_d = P3_WR_WAIT;
      end

      P3_WR_WAIT: begin
        if (dma_rvalid_i) begin
          if (p3_offset_q + 32'd4 >= vec_len_q)
            state_d = DONE_STATE;
          else
            state_d = P3_NORM;
        end
      end

      DONE_STATE: state_d = IDLE;

      default: state_d = IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — sequential state and working registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= IDLE;
      busy_q         <= 1'b0;
      done_q         <= 1'b0;
      p1_offset_q    <= 32'd0;
      p1_elem_base_q <= 32'd0;
      p1_stream_idx_q <= 32'd0;
      max_val_q      <= -8'sd128;
      p2_idx_q       <= 32'd0;
      sum_q          <= 24'd0;
      div_rem_q      <= 17'd0;
      div_quot_q     <= 17'd0;
      div_bit_q      <= 5'd0;
      p3_idx_q       <= 32'd0;
      p3_pack_q      <= 2'd0;
      p3_word_q      <= 32'd0;
      p3_offset_q    <= 32'd0;
      stream_mode_q  <= 1'b0;
    end else begin
      state_q <= state_d;

      case (state_q)
        // ---------------------------------------------------------------
        IDLE: begin
          if (go) begin
            done_q <= 1'b0;
            if (vec_len_q != 32'd0) begin
              busy_q           <= 1'b1;
              stream_mode_q    <= ctrl_wdata_i[1];
              p1_offset_q      <= 32'd0;
              p1_elem_base_q   <= 32'd0;
              p1_stream_idx_q  <= 32'd0;
              max_val_q        <= -8'sd128;
              p2_idx_q         <= 32'd0;
              sum_q            <= 24'd0;
              p3_idx_q         <= 32'd0;
              p3_pack_q        <= 2'd0;
              p3_word_q        <= 32'd0;
              p3_offset_q      <= 32'd0;
            end else begin
              // VEC_LEN=0: immediate done
              done_q <= 1'b1;
            end
          end
        end

        // ---------------------------------------------------------------
        // Phase 1 Stream: accept one INT8 element per beat from s_axis
        // ---------------------------------------------------------------
        P1_STREAM: begin
          if (s_axis_tvalid_i) begin
            buffer[p1_stream_idx_q[$clog2(MaxVecLen)-1:0]] <= s_axis_tdata_i[7:0];
            max_val_q       <= p1_stream_new_max;
            p1_stream_idx_q <= p1_stream_idx_q + 32'd1;
          end
        end

        // ---------------------------------------------------------------
        // Phase 1: DMA Read + Max Find
        // ---------------------------------------------------------------
        P1_RD_WAIT: begin
          if (dma_rvalid_i) begin
            // Unpack 4 INT8 bytes from DMA word into buffer
            buffer[p1_elem_base_q[$clog2(MaxVecLen)-1:0]]     <= dma_rdata_i[7:0];
            buffer[p1_elem_base_q[$clog2(MaxVecLen)-1:0] + 1] <= dma_rdata_i[15:8];
            buffer[p1_elem_base_q[$clog2(MaxVecLen)-1:0] + 2] <= dma_rdata_i[23:16];
            buffer[p1_elem_base_q[$clog2(MaxVecLen)-1:0] + 3] <= dma_rdata_i[31:24];
            // Update running max
            max_val_q <= p1_new_max;
            // Advance counters
            p1_elem_base_q <= p1_elem_base_q + 32'd4;
            p1_offset_q    <= p1_offset_q + 32'd4;
          end
        end

        // ---------------------------------------------------------------
        // Phase 2: Exp + Sum (1 element per cycle, internal)
        // Buffer writes and counter updates are outside the case block,
        // guarded by p2_compute_q, to avoid the high-fanout state decode.
        // ---------------------------------------------------------------
        P2_COMPUTE: ; // intentionally empty — see p2_compute_q block below

        // ---------------------------------------------------------------
        // Phase 2→3: Sequential restoring divider
        // Computes recip = 65536 / sum in 17 cycles
        // ---------------------------------------------------------------
        P2_RECIP: begin
          if (div_new_rem >= div_sum_ext) begin
            div_rem_q  <= div_new_rem - div_sum_ext;
            div_quot_q[div_bit_q] <= 1'b1;
          end else begin
            div_rem_q <= div_new_rem;
          end

          if (div_bit_q != 5'd0)
            div_bit_q <= div_bit_q - 5'd1;
        end

        // ---------------------------------------------------------------
        // Phase 3: Normalize + Pack
        // ---------------------------------------------------------------
        P3_NORM: begin
          // Pack normalized byte into output word
          case (p3_pack_q)
            2'd0: p3_word_q[7:0]   <= core_norm_out;
            2'd1: p3_word_q[15:8]  <= core_norm_out;
            2'd2: p3_word_q[23:16] <= core_norm_out;
            2'd3: p3_word_q[31:24] <= core_norm_out;
          endcase
          p3_idx_q  <= p3_idx_q + 32'd1;
          p3_pack_q <= p3_pack_q + 2'd1;
        end

        // ---------------------------------------------------------------
        P3_WR_WAIT: begin
          if (dma_rvalid_i) begin
            p3_offset_q <= p3_offset_q + 32'd4;
          end
        end

        // ---------------------------------------------------------------
        DONE_STATE: begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
        end

        default: ;
      endcase

      // ---------------------------------------------------------------
      // Phase 2 buffer writes — guarded by registered state decode
      // (p2_compute_q) instead of a decoded combinational gate, breaking
      // the high-fanout path from state_q to all buffer write-enables.
      // ---------------------------------------------------------------
      if (p2_compute_q) begin
        buffer[p2_idx_q[$clog2(MaxVecLen)-1:0]] <= core_exp_val;
        sum_q    <= sum_q + {16'd0, core_exp_val};
        p2_idx_q <= p2_idx_q + 32'd1;

        if (p2_idx_q >= vec_len_q - 32'd1) begin
          div_rem_q  <= 17'd0;
          div_quot_q <= 17'd0;
          div_bit_q  <= 5'd16;
        end
      end
    end
  end

endmodule

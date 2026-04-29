// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Vector MAC Compute Core
 *
 * NUM_LANES parallel signed INT8×INT8 multipliers feeding an explicit
 * reduction adder tree, then a saturating INT32 accumulator. The adder and
 * multiplier microarchitectures are selected at compile time via
 * `arith_pkg::add_kind_e` and `arith_pkg::mul_kind_e`. Optional pipeline
 * stages per arith primitive shift the output without changing throughput.
 *
 * Latency from `valid_i` to accumulator update:
 *   total_pipeline_latency = MUL_PIPE_STAGES + ADD_PIPE_STAGES
 * At default (0,0) the path is single-cycle, matching pre-refactor behavior.
 */
module vec_mac_core
  import arith_pkg::*;
#(
  parameter int unsigned NUM_LANES       = 4,
  parameter add_kind_e   ADD_KIND        = ADD_OPERATOR,
  parameter mul_kind_e   MUL_KIND        = MUL_OPERATOR,
  parameter int unsigned MUL_PIPE_STAGES = 0,
  parameter int unsigned ADD_PIPE_STAGES = 0
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        clear_i,
  input  logic        valid_i,
  input  logic [31:0] a_data_i,
  input  logic [31:0] b_data_i,
  output logic [31:0] result_o
);

  // ─── Compile-time assertions ──────────────────────────────────────────
  initial begin
    assert (NUM_LANES > 0 && (NUM_LANES & (NUM_LANES - 1)) == 0)
      else $fatal(1, "NUM_LANES must be a power of 2, got %0d", NUM_LANES);
    assert (NUM_LANES <= 4)
      else $fatal(1, "NUM_LANES (%0d) exceeds 32-bit bus capacity (max 4)", NUM_LANES);
  end

  localparam int unsigned PROD_W   = 16;     // signed 8x8 -> signed 16
  localparam int unsigned PSUM_W   = 33;     // accommodates accum + 4 products
  localparam int unsigned LOG2_LANES = $clog2(NUM_LANES);

  // ─── Lane multipliers ─────────────────────────────────────────────────
  logic signed [PROD_W-1:0] products [NUM_LANES];

  genvar gi;
  generate
    for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : g_lane
      logic signed [7:0] a_lane, b_lane;
      assign a_lane = signed'(a_data_i[8*gi +: 8]);
      assign b_lane = signed'(b_data_i[8*gi +: 8]);

      mul_signed #(
        .A_W         (8),
        .B_W         (8),
        .P_W         (PROD_W),
        .KIND        (MUL_KIND),
        .PIPE_STAGES (MUL_PIPE_STAGES)
      ) u_mul (
        .clk_i, .rst_ni,
        .a_i  (a_lane),
        .b_i  (b_lane),
        .p_o  (products[gi])
      );
    end
  endgenerate

  // ─── Reduction adder tree (log2(NUM_LANES) levels, single output reg) ──
  // Sign-extend products to PSUM_W
  logic signed [PSUM_W-1:0] prod_ext [NUM_LANES];
  generate
    for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : g_ext
      assign prod_ext[gi] = PSUM_W'(products[gi]);
    end
  endgenerate

  // Build tree level by level. Level 0 has NUM_LANES inputs → NUM_LANES/2 sums.
  // Level k has NUM_LANES/2^k inputs → NUM_LANES/2^(k+1) sums.
  // Final level (k = LOG2_LANES) has 1 sum.
  // ADD_PIPE_STAGES is applied as a single output register on the final tree
  // output, NOT per-level.

  logic signed [PSUM_W-1:0] tree [LOG2_LANES+1][NUM_LANES];

  generate
    for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : g_tree_in
      assign tree[0][gi] = prod_ext[gi];
    end
  endgenerate

  generate
    for (genvar gk = 0; gk < LOG2_LANES; gk = gk + 1) begin : g_tree_lvl
      localparam int unsigned IN_PER_LVL  = NUM_LANES >> gk;
      localparam int unsigned OUT_PER_LVL = IN_PER_LVL >> 1;
      for (genvar gj = 0; gj < OUT_PER_LVL; gj = gj + 1) begin : g_node
        adder #(
          .W           (PSUM_W),
          .KIND        (ADD_KIND),
          .PIPE_STAGES (0)             // tree internals are combinational
        ) u_add (
          .clk_i, .rst_ni,
          .a_i (tree[gk][2*gj]),
          .b_i (tree[gk][2*gj + 1]),
          .s_o (tree[gk+1][gj])
        );
      end
    end
  endgenerate

  // Tree output (combinational)
  logic signed [PSUM_W-1:0] reduction_comb;
  assign reduction_comb = tree[LOG2_LANES][0];

  // Optional output pipeline on the tree (ADD_PIPE_STAGES registers)
  logic signed [PSUM_W-1:0] reduction_pipe;
  generate
    if (ADD_PIPE_STAGES == 0) begin : g_red_p0
      assign reduction_pipe = reduction_comb;
    end else begin : g_red_pN
      logic signed [PSUM_W-1:0] reg_chain [ADD_PIPE_STAGES];
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int i = 0; i < ADD_PIPE_STAGES; i++) reg_chain[i] <= '0;
        end else begin
          reg_chain[0] <= reduction_comb;
          for (int i = 1; i < ADD_PIPE_STAGES; i++) reg_chain[i] <= reg_chain[i-1];
        end
      end
      assign reduction_pipe = reg_chain[ADD_PIPE_STAGES-1];
    end
  endgenerate

  // ─── Saturating accumulator ───────────────────────────────────────────
  logic signed [PSUM_W-1:0] accum_q, accum_unsat, accum_next;

  adder #(
    .W           (PSUM_W),
    .KIND        (ADD_KIND),
    .PIPE_STAGES (0)             // accumulator add is combinational
  ) u_acc_add (
    .clk_i, .rst_ni,
    .a_i (accum_q),
    .b_i (reduction_pipe),
    .s_o (accum_unsat)
  );

  localparam logic signed [PSUM_W-1:0] SAT_MAX = 33'sh0_7FFF_FFFF;
  localparam logic signed [PSUM_W-1:0] SAT_MIN = 33'sh1_8000_0000;

  always_comb begin
    if (accum_unsat > SAT_MAX) accum_next = SAT_MAX;
    else if (accum_unsat < SAT_MIN) accum_next = SAT_MIN;
    else accum_next = accum_unsat;
  end

  // ─── Valid pipelining: track when the reduction output is "for real" ─
  // valid_i pulses propagate through MUL_PIPE_STAGES + ADD_PIPE_STAGES
  // before the accumulator should update.
  localparam int unsigned TOTAL_PIPE = MUL_PIPE_STAGES + ADD_PIPE_STAGES;

  logic valid_pipe [TOTAL_PIPE+1];
  always_comb valid_pipe[0] = valid_i;
  generate
    for (genvar gp = 0; gp < TOTAL_PIPE; gp = gp + 1) begin : g_valid
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) valid_pipe[gp+1] <= 1'b0;
        else         valid_pipe[gp+1] <= valid_pipe[gp];
      end
    end
  endgenerate

  logic accum_update;
  assign accum_update = valid_pipe[TOTAL_PIPE];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      accum_q <= '0;
    end else if (clear_i) begin
      accum_q <= '0;
    end else if (accum_update) begin
      accum_q <= accum_next;
    end
  end

  assign result_o = accum_q[31:0];

endmodule

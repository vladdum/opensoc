// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * adder
 *
 * Parameterized signed adder, dispatching to one of several microarchitectures
 * via the `KIND` parameter (see `arith_pkg::add_kind_e`).
 *
 * Pipelining: `PIPE_STAGES` registers placed at the output. The contract is
 * that `s_o` appears exactly `PIPE_STAGES` cycles after the inputs are sampled.
 * At `PIPE_STAGES==0`, output is purely combinational and `clk_i`/`rst_ni`
 * are unused. Pipeline registers are owned by this dispatcher; body modules
 * must be purely combinational and have no `clk`/`rst` ports.
 *
 * Width: `W` bits, signed. The operator-default body uses native `+`; bodies
 * are responsible for matching the same numerical result modulo 2^W.
 */
module adder
  import arith_pkg::*;
#(
  parameter int unsigned W           = 32,
  parameter add_kind_e   KIND        = ADD_OPERATOR,
  parameter int unsigned PIPE_STAGES = 0
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic                clk_i,
  input  logic                rst_ni,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic signed [W-1:0] a_i,
  input  logic signed [W-1:0] b_i,
  output logic signed [W-1:0] s_o
);

  // ─── Combinational result selected by KIND ────────────────────────────
  logic signed [W-1:0] s_comb;

  generate
    case (KIND)
      ADD_OPERATOR: begin : g_add_op
        assign s_comb = a_i + b_i;
      end

      ADD_RIPPLE: begin : g_add_ripple
        adder_ripple #(.W(W)) u (.a_i, .b_i, .s_o(s_comb));
      end

      ADD_CLA: begin : g_add_cla
        adder_cla #(.W(W)) u (.a_i, .b_i, .s_o(s_comb));
      end

      ADD_KOGGE_STONE: begin : g_add_ks
        adder_kogge_stone #(.W(W)) u (.a_i, .b_i, .s_o(s_comb));
      end

      ADD_BRENT_KUNG: begin : g_add_bk
        adder_brent_kung #(.W(W)) u (.a_i, .b_i, .s_o(s_comb));
      end

      ADD_SKLANSKY: begin : g_add_sk
        adder_sklansky #(.W(W)) u (.a_i, .b_i, .s_o(s_comb));
      end

      default: begin : g_add_default
        assign s_comb = a_i + b_i;
      end
    endcase
  endgenerate

  // ─── Output pipeline (0..N stages) ────────────────────────────────────
  generate
    if (PIPE_STAGES == 0) begin : g_pipe0
      assign s_o = s_comb;
    end else begin : g_pipeN
      logic signed [W-1:0] s_pipe [PIPE_STAGES];
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int i = 0; i < PIPE_STAGES; i++) s_pipe[i] <= '0;
        end else begin
          s_pipe[0] <= s_comb;
          for (int i = 1; i < PIPE_STAGES; i++) s_pipe[i] <= s_pipe[i-1];
        end
      end
      assign s_o = s_pipe[PIPE_STAGES-1];
    end
  endgenerate

endmodule

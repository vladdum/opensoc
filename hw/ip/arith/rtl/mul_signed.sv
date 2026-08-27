// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * mul_signed
 *
 * Parameterized signed multiplier, dispatching to one of several microarchitectures
 * via the `KIND` parameter (see `arith_pkg::mul_kind_e`).
 *
 * Pipelining: `PIPE_STAGES` registers placed at the output. Same contract as
 * `adder`: `p_o` appears exactly `PIPE_STAGES` cycles after the inputs.
 * Pipeline registers are owned by this dispatcher; body modules must be
 * purely combinational and have no `clk`/`rst` ports.
 *
 * Width: A_W × B_W signed → P_W signed (default P_W = A_W + B_W). Operator-
 * default body uses native `*`; bodies must match modulo 2^P_W.
 *
 * Vivado: real body implementations carry `(* use_dsp = "no" *)` so the
 * FPGA-loose synth flow forces LUT mapping; the SoC build uses MUL_OPERATOR
 * only and lets Vivado map to DSP48 freely.
 */
module mul_signed
  import arith_pkg::*;
#(
  parameter int unsigned A_W         = 8,
  parameter int unsigned B_W         = 8,
  parameter int unsigned P_W         = A_W + B_W,
  parameter mul_kind_e   KIND        = MUL_OPERATOR,
  parameter int unsigned PIPE_STAGES = 0
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic                  clk_i,
  input  logic                  rst_ni,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic signed [A_W-1:0] a_i,
  input  logic signed [B_W-1:0] b_i,
  output logic signed [P_W-1:0] p_o
);

  logic signed [P_W-1:0] p_comb;

  generate
    case (KIND)
      MUL_OPERATOR: begin : g_mul_op
        assign p_comb = P_W'(signed'(a_i) * signed'(b_i));
      end

      MUL_ARRAY: begin : g_mul_array
        mul_array #(.A_W(A_W), .B_W(B_W), .P_W(P_W)) u (.a_i, .b_i, .p_o(p_comb));
      end

      MUL_BOOTH4: begin : g_mul_b4
        mul_booth4 #(.A_W(A_W), .B_W(B_W), .P_W(P_W)) u (.a_i, .b_i, .p_o(p_comb));
      end

      MUL_WALLACE: begin : g_mul_wt
        mul_wallace #(.A_W(A_W), .B_W(B_W), .P_W(P_W)) u (.a_i, .b_i, .p_o(p_comb));
      end

      MUL_DADDA: begin : g_mul_dt
        mul_dadda #(.A_W(A_W), .B_W(B_W), .P_W(P_W)) u (.a_i, .b_i, .p_o(p_comb));
      end

      default: begin : g_mul_default
        assign p_comb = P_W'(signed'(a_i) * signed'(b_i));
      end
    endcase
  endgenerate

  generate
    if (PIPE_STAGES == 0) begin : g_pipe0
      assign p_o = p_comb;
    end else begin : g_pipeN
      logic signed [P_W-1:0] p_pipe [PIPE_STAGES];
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int i = 0; i < PIPE_STAGES; i++) p_pipe[i] <= '0;
        end else begin
          p_pipe[0] <= p_comb;
          for (int i = 1; i < PIPE_STAGES; i++) p_pipe[i] <= p_pipe[i-1];
        end
      end
      assign p_o = p_pipe[PIPE_STAGES-1];
    end
  endgenerate

endmodule

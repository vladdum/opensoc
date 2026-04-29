// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * mul_array
 *
 * Combinational signed array multiplier. Shift-and-add row reduction.
 *
 * Signed handling: a_i is sign-extended to A_W+B_W bits. b_i contributes
 * one row per bit. Rows 0..B_W-2 add the sign-extended a; the MSB row
 * (b_i[B_W-1] = sign bit) subtracts it instead — this implements the
 * two's-complement decomposition  b = -b[N-1]*2^(N-1) + sum b[i]*2^i.
 */
module mul_array
  (* use_dsp = "no" *)
#(
  parameter int unsigned A_W = 8,
  parameter int unsigned B_W = 8,
  parameter int unsigned P_W = A_W + B_W
) (
  input  logic signed [A_W-1:0] a_i,
  input  logic signed [B_W-1:0] b_i,
  output logic signed [P_W-1:0] p_o
);

  localparam int unsigned WI = A_W + B_W;
  logic signed [WI-1:0] a_ext;
  assign a_ext = WI'(signed'(a_i));

  // Build PP rows. Rows 0..B_W-2 use original b_i bits (positive weight).
  // Row B_W-1 uses the sign bit of b and is negated.
  logic signed [WI-1:0] pp [B_W];
  genvar gi;
  generate
    for (gi = 0; gi < B_W - 1; gi = gi + 1) begin : g_pp_pos
      assign pp[gi] = b_i[gi] ? (a_ext <<< gi) : '0;
    end
  endgenerate
  assign pp[B_W-1] = b_i[B_W-1] ? (-(a_ext <<< (B_W-1))) : '0;

  // Reduce via ripple chain of explicit adds.
  logic signed [WI-1:0] acc [B_W];
  assign acc[0] = pp[0];
  generate
    for (gi = 1; gi < B_W; gi = gi + 1) begin : g_acc
      assign acc[gi] = acc[gi-1] + pp[gi];
    end
  endgenerate

  assign p_o = P_W'(acc[B_W-1]);

endmodule

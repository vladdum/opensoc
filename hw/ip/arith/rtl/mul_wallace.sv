// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * mul_wallace
 *
 * Combinational Wallace-tree signed multiplier. Builds partial products,
 * reduces with bit-parallel 3:2 carry-save adders until two vectors remain,
 * then sums with a final adder.
 *
 * For A_W=8, B_W=8: 8 partial-product rows reduce in 4 CSA levels.
 * Hand-unrolled reduction sequence (8 -> 6 -> 4 -> 3 -> 2).
 */
module mul_wallace
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

  logic signed [P_W-1:0] a_ext;
  assign a_ext = P_W'(signed'(a_i));

  // Partial products. Rows 0..B_W-2 add the sign-extended a; the MSB row
  // (b_i sign bit) subtracts it — implements signed b decomposition
  // b = -b[N-1]*2^(N-1) + sum b[i]*2^i.
  logic signed [P_W-1:0] pp [B_W];
  genvar gi;
  generate
    for (gi = 0; gi < B_W - 1; gi = gi + 1) begin : g_pp_pos
      assign pp[gi] = b_i[gi] ? (a_ext <<< gi) : '0;
    end
  endgenerate
  assign pp[B_W-1] = b_i[B_W-1] ? (-(a_ext <<< (B_W-1))) : '0;

  // Bit-parallel 3:2 CSA functions
  function automatic logic signed [P_W-1:0] csa_sum(input logic signed [P_W-1:0] x, y, z);
    return x ^ y ^ z;
  endfunction
  function automatic logic signed [P_W-1:0] csa_carry(input logic signed [P_W-1:0] x, y, z);
    return ((x & y) | (x & z) | (y & z)) <<< 1;
  endfunction

  // Level 1: 8 rows -> 6 rows (two CSA(3,3) groups + 2 passthrough)
  // Group A: pp[0], pp[1], pp[2] -> s_a, c_a
  // Group B: pp[3], pp[4], pp[5] -> s_b, c_b
  // Passthrough: pp[6], pp[7]
  logic signed [P_W-1:0] s_a, c_a, s_b, c_b;
  assign s_a = csa_sum(pp[0], pp[1], pp[2]);
  assign c_a = csa_carry(pp[0], pp[1], pp[2]);
  assign s_b = csa_sum(pp[3], pp[4], pp[5]);
  assign c_b = csa_carry(pp[3], pp[4], pp[5]);

  // Level 2: 6 rows {s_a, c_a, s_b, c_b, pp[6], pp[7]} -> 4 rows
  // CSA(s_a, c_a, s_b) -> s_c, c_c
  // CSA(c_b, pp[6], pp[7]) -> s_d, c_d
  logic signed [P_W-1:0] s_c, c_c, s_d, c_d;
  assign s_c = csa_sum  (s_a, c_a, s_b);
  assign c_c = csa_carry(s_a, c_a, s_b);
  assign s_d = csa_sum  (c_b, pp[6], pp[7]);
  assign c_d = csa_carry(c_b, pp[6], pp[7]);

  // Level 3: 4 rows {s_c, c_c, s_d, c_d} -> 3 rows via CSA(s_c, c_c, s_d)
  logic signed [P_W-1:0] s_e, c_e;
  assign s_e = csa_sum  (s_c, c_c, s_d);
  assign c_e = csa_carry(s_c, c_c, s_d);

  // Level 4: 3 rows {s_e, c_e, c_d} -> 2 rows via CSA
  logic signed [P_W-1:0] s_f, c_f;
  assign s_f = csa_sum  (s_e, c_e, c_d);
  assign c_f = csa_carry(s_e, c_e, c_d);

  // Final adder
  assign p_o = s_f + c_f;

endmodule

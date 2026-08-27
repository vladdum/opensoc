// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * mul_dadda
 *
 * Combinational Dadda-tree signed multiplier. Like Wallace but uses the
 * minimum number of 3:2 CSAs at each reduction level to hit the Dadda
 * height sequence. For B_W=8: heights 8 -> 6 -> 4 -> 3 -> 2.
 *
 * For A_W=B_W=8 with bit-parallel reduction, the actual gate count differs
 * from Wallace at each level. The functional output is identical.
 */
module mul_dadda
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

  function automatic logic signed [P_W-1:0] csa_sum(input logic signed [P_W-1:0] x, y, z);
    return x ^ y ^ z;
  endfunction
  function automatic logic signed [P_W-1:0] csa_carry(input logic signed [P_W-1:0] x, y, z);
    return ((x & y) | (x & z) | (y & z)) <<< 1;
  endfunction

  // Level 1: 8 -> 6 with 2 CSAs (each 3->2 nets -1, so 8 - 2 = 6).
  logic signed [P_W-1:0] s1, c1;
  assign s1 = csa_sum  (pp[0], pp[1], pp[2]);
  assign c1 = csa_carry(pp[0], pp[1], pp[2]);
  logic signed [P_W-1:0] s1b, c1b;
  assign s1b = csa_sum  (pp[3], pp[4], pp[5]);
  assign c1b = csa_carry(pp[3], pp[4], pp[5]);
  // L1 outputs: {s1, c1, s1b, c1b, pp[6], pp[7]} = 6 vectors.

  // Level 2: 6 -> 4 with 2 CSAs.
  logic signed [P_W-1:0] s2a, c2a, s2b, c2b;
  assign s2a = csa_sum  (s1,  c1,  s1b);
  assign c2a = csa_carry(s1,  c1,  s1b);
  assign s2b = csa_sum  (c1b, pp[6], pp[7]);
  assign c2b = csa_carry(c1b, pp[6], pp[7]);
  // L2 outputs: {s2a, c2a, s2b, c2b} = 4 vectors.

  // Level 3: 4 -> 3 with 1 CSA.
  logic signed [P_W-1:0] s3, c3;
  assign s3 = csa_sum  (s2a, c2a, s2b);
  assign c3 = csa_carry(s2a, c2a, s2b);
  // L3 outputs: {s3, c3, c2b} = 3 vectors.

  // Level 4: 3 -> 2 with 1 CSA.
  logic signed [P_W-1:0] s4, c4;
  assign s4 = csa_sum  (s3, c3, c2b);
  assign c4 = csa_carry(s3, c3, c2b);

  assign p_o = s4 + c4;

endmodule

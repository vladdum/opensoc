// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * adder_ripple
 *
 * Combinational ripple-carry adder. Explicit full-adder chain to guarantee
 * the structure regardless of synthesis tool. Signed N-bit + signed N-bit →
 * signed N-bit (modular).
 */
module adder_ripple #(
  parameter int unsigned W = 32
) (
  input  logic signed [W-1:0] a_i,
  input  logic signed [W-1:0] b_i,
  output logic signed [W-1:0] s_o
);

  logic [W:0] c;
  assign c[0] = 1'b0;

  genvar gi;
  generate
    for (gi = 0; gi < W; gi = gi + 1) begin : g_fa
      // Full adder
      assign s_o[gi]   = a_i[gi] ^ b_i[gi] ^ c[gi];
      assign c[gi+1]   = (a_i[gi] & b_i[gi]) | (a_i[gi] & c[gi]) | (b_i[gi] & c[gi]);
    end
  endgenerate

endmodule

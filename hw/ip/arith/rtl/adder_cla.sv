// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * adder_cla
 *
 * Combinational carry-lookahead adder built from 4-bit CLA blocks chained
 * by their block-carry-out. Width W is rounded up to a multiple of 4
 * internally; spurious upper bits are dropped.
 */
module adder_cla #(
  parameter int unsigned W = 32
) (
  input  logic signed [W-1:0] a_i,
  input  logic signed [W-1:0] b_i,
  output logic signed [W-1:0] s_o
);

  localparam int unsigned WP = ((W + 3) / 4) * 4;        // padded width
  localparam int unsigned NB = WP / 4;                    // number of blocks

  logic [WP-1:0] a_p, b_p, s_p;
  assign a_p = WP'($signed(a_i));
  assign b_p = WP'($signed(b_i));

  logic [NB:0] cblk;          // block-level carries
  assign cblk[0] = 1'b0;

  genvar gb, gi;
  generate
    for (gb = 0; gb < NB; gb = gb + 1) begin : g_blk
      // Bit-level G,P inside this block
      logic [3:0] G, P;
      // Internal carries within block
      logic [3:0] c_int;
      assign c_int[0] = cblk[gb];

      for (gi = 0; gi < 4; gi = gi + 1) begin : g_bit
        assign G[gi] = a_p[gb*4 + gi] & b_p[gb*4 + gi];
        assign P[gi] = a_p[gb*4 + gi] ^ b_p[gb*4 + gi];
      end

      // Internal carry expansion (CLA inside the 4-bit block)
      assign c_int[1] = G[0] | (P[0] & cblk[gb]);
      assign c_int[2] = G[1] | (P[1] & G[0]) | (P[1] & P[0] & cblk[gb]);
      assign c_int[3] = G[2] | (P[2] & G[1]) | (P[2] & P[1] & G[0])
                              | (P[2] & P[1] & P[0] & cblk[gb]);

      // Sum bits
      for (gi = 0; gi < 4; gi = gi + 1) begin : g_sum
        assign s_p[gb*4 + gi] = P[gi] ^ c_int[gi];
      end

      // Block carry-out
      assign cblk[gb+1] = G[3] | (P[3] & G[2]) | (P[3] & P[2] & G[1])
                          | (P[3] & P[2] & P[1] & G[0])
                          | (P[3] & P[2] & P[1] & P[0] & cblk[gb]);
    end
  endgenerate

  assign s_o = s_p[W-1:0];

endmodule

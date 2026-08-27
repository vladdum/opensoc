// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * adder_sklansky
 *
 * Combinational Sklansky parallel-prefix adder. log2(W) levels, smaller
 * cell count than Kogge-Stone but with growing fan-out at each level
 * (load increases as 2^k).
 */
module adder_sklansky #(
  parameter int unsigned W = 32
) (
  input  logic signed [W-1:0] a_i,
  input  logic signed [W-1:0] b_i,
  output logic signed [W-1:0] s_o
);

  localparam int unsigned WP = 1 << $clog2(W);
  localparam int unsigned LEVELS = $clog2(WP);

  logic [WP-1:0] a_p, b_p;
  assign a_p = WP'($signed(a_i));
  assign b_p = WP'($signed(b_i));

  logic [WP-1:0] G [LEVELS+1];
  logic [WP-1:0] P [LEVELS+1];

  genvar gi, gk;
  generate
    for (gi = 0; gi < WP; gi = gi + 1) begin : g_init
      assign G[0][gi] = a_p[gi] & b_p[gi];
      assign P[0][gi] = a_p[gi] ^ b_p[gi];
    end
  endgenerate

  // Sklansky: at level k, cells in the right half of each 2^(k+1)-wide group
  // merge with the leftmost-merged cell of the left half (position group_base + 2^k - 1).
  generate
    for (gk = 0; gk < LEVELS; gk = gk + 1) begin : g_lvl
      localparam int unsigned PAIR  = 1 << (gk + 1);
      localparam int unsigned HALF  = 1 << gk;
      for (gi = 0; gi < WP; gi = gi + 1) begin : g_cell
        // Position within the PAIR-wide group
        localparam int unsigned IN_GROUP = (gi & (PAIR - 1));
        if (IN_GROUP >= HALF) begin : g_merge
          // Merge with the cell at position (gi - IN_GROUP + HALF - 1)
          localparam int unsigned SRC = (gi - IN_GROUP) + HALF - 1;
          assign G[gk+1][gi] = G[gk][gi] | (P[gk][gi] & G[gk][SRC]);
          assign P[gk+1][gi] = P[gk][gi] & P[gk][SRC];
        end else begin : g_pass
          assign G[gk+1][gi] = G[gk][gi];
          assign P[gk+1][gi] = P[gk][gi];
        end
      end
    end
  endgenerate

  logic [WP:0] c;
  assign c[0] = 1'b0;
  generate
    for (gi = 0; gi < WP; gi = gi + 1) begin : g_c
      assign c[gi+1] = G[LEVELS][gi];
    end
  endgenerate

  logic [WP-1:0] s_p;
  generate
    for (gi = 0; gi < WP; gi = gi + 1) begin : g_s
      assign s_p[gi] = P[0][gi] ^ c[gi];
    end
  endgenerate

  assign s_o = s_p[W-1:0];

endmodule

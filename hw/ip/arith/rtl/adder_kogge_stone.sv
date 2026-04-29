// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * adder_kogge_stone
 *
 * Combinational Kogge-Stone parallel-prefix adder. log2(W) merge levels;
 * fan-out doubles per level (high area, fastest delay).
 */
module adder_kogge_stone #(
  parameter int unsigned W = 32
) (
  input  logic signed [W-1:0] a_i,
  input  logic signed [W-1:0] b_i,
  output logic signed [W-1:0] s_o
);

  localparam int unsigned LEVELS = $clog2(W);

  // Bit-level generate / propagate
  logic [W-1:0] G0, P0;
  genvar gi, gk;
  generate
    for (gi = 0; gi < W; gi = gi + 1) begin : g_bit
      assign G0[gi] = a_i[gi] & b_i[gi];
      assign P0[gi] = a_i[gi] ^ b_i[gi];
    end
  endgenerate

  // Prefix levels
  logic [W-1:0] G [LEVELS+1];
  logic [W-1:0] P [LEVELS+1];
  assign G[0] = G0;
  assign P[0] = P0;

  generate
    for (gk = 0; gk < LEVELS; gk = gk + 1) begin : g_lvl
      localparam int unsigned STRIDE = 1 << gk;
      for (gi = 0; gi < W; gi = gi + 1) begin : g_cell
        if (gi < STRIDE) begin : g_passthru
          assign G[gk+1][gi] = G[gk][gi];
          assign P[gk+1][gi] = P[gk][gi];
        end else begin : g_merge
          assign G[gk+1][gi] = G[gk][gi] | (P[gk][gi] & G[gk][gi - STRIDE]);
          assign P[gk+1][gi] = P[gk][gi] & P[gk][gi - STRIDE];
        end
      end
    end
  endgenerate

  // Carries: c[i] = G[LEVELS][i-1]; c[0] = 0
  logic [W:0] c;
  assign c[0] = 1'b0;
  generate
    for (gi = 0; gi < W; gi = gi + 1) begin : g_carry
      assign c[gi+1] = G[LEVELS][gi];
    end
  endgenerate

  // Sum
  generate
    for (gi = 0; gi < W; gi = gi + 1) begin : g_sum
      assign s_o[gi] = P0[gi] ^ c[gi];
    end
  endgenerate

endmodule

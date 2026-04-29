// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * adder_brent_kung
 *
 * Combinational Brent-Kung parallel-prefix adder. Two-phase prefix tree:
 * forward sweep (log2(W) levels) builds the backbone; reverse sweep
 * (log2(W)-1 levels) fills the gaps. Lower fan-out and area than
 * Kogge-Stone; roughly twice the delay.
 *
 * Implementation pads W to the next power-of-2 internally for a regular
 * tree structure, then masks the result to W bits.
 */
module adder_brent_kung #(
  parameter int unsigned W = 32
) (
  input  logic signed [W-1:0] a_i,
  input  logic signed [W-1:0] b_i,
  output logic signed [W-1:0] s_o
);

  // Pad to power-of-2
  localparam int unsigned WP = 1 << $clog2(W);
  localparam int unsigned LEVELS = $clog2(WP);

  logic [WP-1:0] a_p, b_p;
  assign a_p = WP'($signed(a_i));
  assign b_p = WP'($signed(b_i));

  logic [WP-1:0] G [LEVELS+1];
  logic [WP-1:0] P [LEVELS+1];

  genvar gi, gk;
  // Bit G,P
  generate
    for (gi = 0; gi < WP; gi = gi + 1) begin : g_init
      assign G[0][gi] = a_p[gi] & b_p[gi];
      assign P[0][gi] = a_p[gi] ^ b_p[gi];
    end
  endgenerate

  // Forward sweep — at level k, merge cells at i=2^(k+1)*m+2^(k+1)-1
  // with their pair at i-2^k.
  generate
    for (gk = 0; gk < LEVELS; gk = gk + 1) begin : g_fwd
      localparam int unsigned STRIDE = 1 << gk;
      localparam int unsigned PAIR   = 1 << (gk+1);
      for (gi = 0; gi < WP; gi = gi + 1) begin : g_cell
        if ((gi % PAIR) == (PAIR - 1)) begin : g_merge
          assign G[gk+1][gi] = G[gk][gi] | (P[gk][gi] & G[gk][gi - STRIDE]);
          assign P[gk+1][gi] = P[gk][gi] & P[gk][gi - STRIDE];
        end else begin : g_pass
          assign G[gk+1][gi] = G[gk][gi];
          assign P[gk+1][gi] = P[gk][gi];
        end
      end
    end
  endgenerate

  // Reverse sweep — fill in non-backbone cells using the backbone above.
  logic [WP-1:0] G_post [LEVELS];
  logic [WP-1:0] P_post [LEVELS];

  // Initialize post[LEVELS-1] from forward output
  assign G_post[LEVELS-1] = G[LEVELS];
  assign P_post[LEVELS-1] = P[LEVELS];

  generate
    for (gk = LEVELS - 1; gk > 0; gk = gk - 1) begin : g_rev
      localparam int unsigned STRIDE = 1 << (gk-1);
      localparam int unsigned PAIR   = 1 << gk;
      for (gi = 0; gi < WP; gi = gi + 1) begin : g_cell
        if (gi >= STRIDE && (gi % PAIR) == (STRIDE - 1) && gi >= PAIR) begin : g_fill
          assign G_post[gk-1][gi] = G_post[gk][gi]
                                     | (P_post[gk][gi] & G_post[gk][gi - STRIDE]);
          assign P_post[gk-1][gi] = P_post[gk][gi] & P_post[gk][gi - STRIDE];
        end else begin : g_pass_rev
          assign G_post[gk-1][gi] = G_post[gk][gi];
          assign P_post[gk-1][gi] = P_post[gk][gi];
        end
      end
    end
  endgenerate

  // Carries
  logic [WP:0] c;
  assign c[0] = 1'b0;
  generate
    for (gi = 0; gi < WP; gi = gi + 1) begin : g_carry
      assign c[gi+1] = G_post[0][gi];
    end
  endgenerate

  // Sum
  logic [WP-1:0] s_p;
  generate
    for (gi = 0; gi < WP; gi = gi + 1) begin : g_sum
      assign s_p[gi] = P[0][gi] ^ c[gi];
    end
  endgenerate

  assign s_o = s_p[W-1:0];

endmodule

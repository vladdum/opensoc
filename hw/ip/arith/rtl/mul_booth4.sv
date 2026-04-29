// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * mul_booth4
 *
 * Combinational radix-4 Booth-encoded signed multiplier. Each 3-bit window
 * (b[i+1], b[i], b[i-1]) selects one of {-2A, -A, 0, +A, +2A}, producing
 * ceil((B_W+1)/2) partial products. Sum via ripple accumulation.
 */
module mul_booth4
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

  // Pad B with one bit at the bottom (b[-1] = 0) and one at the top
  // (sign extension for the last window).
  localparam int unsigned BP = (B_W + 2);
  localparam int unsigned NP = (B_W + 1 + 1) / 2;
  localparam int unsigned WI = A_W + BP + 2;

  logic signed [BP-1:0] b_pad;
  assign b_pad = {b_i[B_W-1], b_i, 1'b0};

  logic signed [WI-1:0] a_ext;
  assign a_ext = WI'(signed'(a_i));

  // Build NP partial products
  logic signed [WI-1:0] pp [NP];
  genvar gi;
  generate
    for (gi = 0; gi < NP; gi = gi + 1) begin : g_pp
      logic [2:0] win;
      assign win = b_pad[2*gi +: 3];
      always_comb begin
        case (win)
          3'b000, 3'b111: pp[gi] = '0;
          3'b001, 3'b010: pp[gi] = (a_ext) <<< (2*gi);
          3'b011        : pp[gi] = (a_ext <<< 1) <<< (2*gi);
          3'b100        : pp[gi] = (-(a_ext <<< 1)) <<< (2*gi);
          3'b101, 3'b110: pp[gi] = (-a_ext) <<< (2*gi);
          default       : pp[gi] = '0;
        endcase
      end
    end
  endgenerate

  // Sum partial products via ripple
  logic signed [WI-1:0] acc [NP];
  assign acc[0] = pp[0];
  generate
    for (gi = 1; gi < NP; gi = gi + 1) begin : g_acc
      assign acc[gi] = acc[gi-1] + pp[gi];
    end
  endgenerate

  assign p_o = P_W'(acc[NP-1]);

endmodule

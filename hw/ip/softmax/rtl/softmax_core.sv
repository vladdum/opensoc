// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Softmax Compute Core
 *
 * Pure combinational module providing:
 *   1. exp() lookup via exp_lut (Phase 2)
 *   2. Normalization multiply+shift (Phase 3)
 *
 * The FSM, DMA engine, and buffer management live in softmax.sv.
 */
module softmax_core (
  // Phase 2: exp lookup
  input  logic [7:0]  exp_index_i,   // |max - x|, range 0..255
  output logic [7:0]  exp_val_o,     // exp LUT output (UINT8, 0..255)

  // Phase 3: normalize
  input  logic [7:0]  norm_exp_i,    // exp value to normalize
  input  logic [16:0] norm_recip_i,  // reciprocal = 65536 / sum
  output logic [7:0]  norm_out_o     // normalized output (UINT8)
);

  // -------------------------------------------------------------------------
  // Exp LUT instance
  // -------------------------------------------------------------------------
  exp_lut u_exp_lut (
    .index_i (exp_index_i),
    .exp_o   (exp_val_o)
  );

  // -------------------------------------------------------------------------
  // Normalize: result = (exp_val * recip) >> 8, clamped to 255
  // -------------------------------------------------------------------------
  // Max product: 255 * 257 = 65535 (16 bits). After >> 8: 255.
  // Clamp handles any edge-case overflow.
  logic [24:0] norm_product;
  assign norm_product = {17'd0, norm_exp_i} * {8'd0, norm_recip_i};
  assign norm_out_o = |norm_product[24:16] ? 8'd255 : norm_product[15:8];

endmodule

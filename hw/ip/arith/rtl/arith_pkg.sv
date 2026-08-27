// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * arith_pkg
 *
 * Selector enumerations for the adder and multiplier microarchitectures
 * exposed by `adder.sv` and `mul_signed.sv`. Defaults (`*_OPERATOR`) match
 * the synthesizer-inferred behavior — i.e. plain `+` / `*` operators.
 *
 * Used by `vec_mac_core` and (in the future) any other accelerator that
 * wants compile-time-selectable arithmetic primitives for PPA studies.
 */
package arith_pkg;

  typedef enum logic [2:0] {
    ADD_OPERATOR    = 3'd0,  // synthesis-inferred `+` (control)
    ADD_RIPPLE      = 3'd1,
    ADD_CLA         = 3'd2,
    ADD_KOGGE_STONE = 3'd3,
    ADD_BRENT_KUNG  = 3'd4,
    ADD_SKLANSKY    = 3'd5
  } add_kind_e;

  typedef enum logic [2:0] {
    MUL_OPERATOR = 3'd0,  // synthesis-inferred `*` (control)
    MUL_ARRAY    = 3'd1,
    MUL_BOOTH4   = 3'd2,
    MUL_WALLACE  = 3'd3,
    MUL_DADDA    = 3'd4
  } mul_kind_e;

endpackage

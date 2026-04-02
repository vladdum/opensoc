// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Minimal stub of keymgr_reg_pkg — only the constants needed by keymgr_pkg.
// Values match OpenTitan upstream (hw/ip/keymgr/rtl/keymgr_reg_pkg.sv).

package keymgr_reg_pkg;

  parameter int NumSwBindingReg = 8;
  parameter int NumSaltReg      = 8;

endpackage

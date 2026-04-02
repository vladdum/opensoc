// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Minimal stub of lc_ctrl_reg_pkg — only the constants needed by lc_ctrl_pkg.
// Values match OpenTitan upstream (hw/ip/lc_ctrl/rtl/lc_ctrl_reg_pkg.sv).

package lc_ctrl_reg_pkg;

  parameter int SiliconCreatorIdWidth = 16;
  parameter int ProductIdWidth        = 16;
  parameter int RevisionIdWidth       = 8;

endpackage

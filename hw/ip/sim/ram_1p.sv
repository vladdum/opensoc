// Copyright OpenSoC contributors (adapted from lowRISC Ibex).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Single-port RAM with 1 cycle read/write delay, 32-bit words.
 *
 * Self-contained behavioural model for Verilator simulation.
 * Drop-in replacement for the lowRISC ram_1p with no prim dependencies.
 */

module ram_1p #(
  parameter int Depth       = 128,
  parameter     MemInitFile = ""
) (
  input               clk_i,
  input               rst_ni,

  input               req_i,
  input               we_i,
  input        [ 3:0] be_i,
  input        [31:0] addr_i,
  input        [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o
);

  localparam int Aw = $clog2(Depth);

  logic [31:0] mem [0:Depth-1];

  logic [Aw-1:0] addr_idx;
  assign addr_idx = addr_i[Aw-1+2:2];

  // -------------------------------------------------------------------------
  // DPI exports for Verilator memutil (simutil_memload / get / set)
  // -------------------------------------------------------------------------
`ifndef SYNTHESIS
  export "DPI-C" task simutil_memload;
  task simutil_memload;
    input string file;
    $readmemh(file, mem);
  endtask

  export "DPI-C" function simutil_set_mem;
  function int simutil_set_mem(input int index, input bit [311:0] val);
    int valid;
    valid = index >= Depth ? 0 : 1;
    if (valid == 1) mem[index] = val[31:0];
    return valid;
  endfunction

  export "DPI-C" function simutil_get_mem;
  function int simutil_get_mem(input int index, output bit [311:0] val);
    int valid;
    valid = index >= Depth ? 0 : 1;
    if (valid == 1) begin
      val        = 0;
      val[31:0]  = mem[index];
    end
    return valid;
  endfunction
`endif

  // Initialise from file if provided.
  initial begin
    if (MemInitFile != "") begin
      $readmemh(MemInitFile, mem);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_o <= 1'b0;
      rdata_o  <= 32'b0;
    end else begin
      rvalid_o <= req_i;
      if (req_i) begin
        if (we_i) begin
          if (be_i[0]) mem[addr_idx][ 7: 0] <= wdata_i[ 7: 0];
          if (be_i[1]) mem[addr_idx][15: 8] <= wdata_i[15: 8];
          if (be_i[2]) mem[addr_idx][23:16] <= wdata_i[23:16];
          if (be_i[3]) mem[addr_idx][31:24] <= wdata_i[31:24];
        end else begin
          rdata_o <= mem[addr_idx];
        end
      end
    end
  end

endmodule

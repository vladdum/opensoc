// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Technology-dispatching RAM wrapper.
//
// Selects implementation based on compile-time defines already set per flow:
//   FPGA_XILINX=1  →  Xilinx XPM xpm_memory_spram  (Vivado FPGA)
//   SYNTHESIS=1    →  sky130_sram_1rw_32x16384 blackbox stub (ASIC)
//   (neither)      →  ram_1p behavioral model  (Verilator simulation)
//
// External interface is identical to ram_1p so opensoc_top needs only a
// module-name swap.

`ifdef SYNTHESIS
// Sky130 SRAM blackbox stub (OpenRAM port convention, active-low enables).
// The actual macro LEF/Liberty is provided by the PDK during place-and-route.
(* blackbox *)
module sky130_sram_1rw_32x16384 (
  input  logic        clk,
  input  logic        csb,    // chip-select bar (active-low)
  input  logic        web,    // write-enable bar (active-low)
  input  logic [ 3:0] wmask,  // byte write mask (active-high)
  input  logic [13:0] addr,
  input  logic [31:0] din,
  output logic [31:0] dout
);
endmodule
`endif

module opensoc_ram #(
  parameter int unsigned Depth       = 131072,
  parameter              MemInitFile = ""
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o
);

`ifdef FPGA_XILINX
  // ---------------------------------------------------------------------------
  // Xilinx XPM — inferred as BRAM by Vivado
  // ---------------------------------------------------------------------------
  localparam int unsigned Aw = $clog2(Depth);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rvalid_o <= 1'b0;
    else         rvalid_o <= req_i;
  end

  // Init file not supported for XPM path; pre-load via simulation or ELF loader
  xpm_memory_spram #(
    .ADDR_WIDTH_A        (Aw),
    .BYTE_WRITE_WIDTH_A  (8),
    .WRITE_DATA_WIDTH_A  (32),
    .READ_DATA_WIDTH_A   (32),
    .READ_LATENCY_A      (1),
    .MEMORY_PRIMITIVE    ("block"),
    .MEMORY_INIT_FILE    ("none"),
    .USE_MEM_INIT_MMI    (1)
  ) u_xpm (
    .clka   (clk_i),
    .ena    (req_i),
    .wea    (be_i),
    .addra  (addr_i[Aw+1:2]),
    .dina   (wdata_i),
    .douta  (rdata_o),
    .rsta   (1'b0),
    .regcea (1'b1),
    .sleep  (1'b0),
    .injectdbiterra (1'b0),
    .injectsbiterra (1'b0),
    .dbiterra (),
    .sbiterra ()
  );

`elsif SYNTHESIS
  // ---------------------------------------------------------------------------
  // Sky130 SRAM stub (blackbox — macro placed by OpenLane)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rvalid_o <= 1'b0;
    else         rvalid_o <= req_i;
  end

  logic [31:0] sram_dout;

  sky130_sram_1rw_32x16384 u_sram (
    .clk   (clk_i),
    .csb   (~req_i),
    .web   (~we_i),
    .wmask (be_i),
    .addr  (addr_i[15:2]),
    .din   (wdata_i),
    .dout  (sram_dout)
  );

  assign rdata_o = sram_dout;

`else
  // ---------------------------------------------------------------------------
  // Simulation — behavioural ram_1p (unchanged)
  // ---------------------------------------------------------------------------
  ram_1p #(
    .Depth       (Depth),
    .MemInitFile (MemInitFile)
  ) u_ram (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .req_i   (req_i),
    .we_i    (we_i),
    .be_i    (be_i),
    .addr_i  (addr_i),
    .wdata_i (wdata_i),
    .rvalid_o(rvalid_o),
    .rdata_o (rdata_o)
  );

`endif

endmodule

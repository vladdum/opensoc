// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Simulation-only wrapper around opensoc_top.
 *
 * Adds:
 *  - I2C loopback: open-drain wired-AND of the HW I2C master and PIO GPIO
 *    pins so a PIO I2C slave can communicate with the hardware I2C controller.
 *    Pin assignment: gpio[0] = SDA, gpio[1] = SCL (matches i2c.pio.h).
 *  - ibex_tracer connected via hierarchical references to the RVFI signals
 *    declared inside opensoc_top (requires RVFI define).
 *  - DPI-C exports for MHPM performance counters consumed by the Verilator
 *    C++ harness via ibex_pcounts.
 */
module opensoc_top_wrapper
  import axi_pkg::*;
  import opensoc_derived_config_pkg::*;
(
  input  logic IO_CLK,
  input  logic IO_RST_N,

  output logic uart_tx_o,
  input  logic uart_rx_i
);

  // -------------------------------------------------------------------------
  // I2C loopback wiring
  // -------------------------------------------------------------------------
  // Open-drain wired-AND: bus is HIGH unless either side asserts OE (pulls low).
  // Both I2C controller and PIO slave keep output data at 0; OE=1 drives low.
  logic        i2c_scl_oe, i2c_sda_oe;
  logic [31:0] gpio_oe;

  wire sda_bus = ~i2c_sda_oe & ~gpio_oe[0];
  wire scl_bus = ~i2c_scl_oe & ~gpio_oe[1];

  opensoc_top u_opensoc_top (
    .IO_CLK     (IO_CLK    ),
    .IO_RST_N   (IO_RST_N  ),
    .uart_tx_o  (uart_tx_o ),
    .uart_rx_i  (uart_rx_i ),

    .gpio_i     ({30'd0, scl_bus, sda_bus}),
    .gpio_o     (             ),
    .gpio_oe    (gpio_oe      ),

    .i2c_scl_o  (             ),
    .i2c_scl_oe (i2c_scl_oe  ),
    .i2c_scl_i  (scl_bus      ),
    .i2c_sda_o  (             ),
    .i2c_sda_oe (i2c_sda_oe  ),
    .i2c_sda_i  (sda_bus      )
  );

`ifdef RVFI
  ibex_tracer u_ibex_tracer (
    .clk_i                       (u_opensoc_top.clk_sys                        ),
    .rst_ni                      (u_opensoc_top.rst_sys_n                       ),
    .hart_id_i                   (32'b0                                         ),
    .rvfi_valid                  (u_opensoc_top.rvfi_valid                      ),
    .rvfi_order                  (u_opensoc_top.rvfi_order                      ),
    .rvfi_insn                   (u_opensoc_top.rvfi_insn                       ),
    .rvfi_trap                   (u_opensoc_top.rvfi_trap                       ),
    .rvfi_halt                   (u_opensoc_top.rvfi_halt                       ),
    .rvfi_intr                   (u_opensoc_top.rvfi_intr                       ),
    .rvfi_mode                   (u_opensoc_top.rvfi_mode                       ),
    .rvfi_ixl                    (u_opensoc_top.rvfi_ixl                        ),
    .rvfi_rs1_addr               (u_opensoc_top.rvfi_rs1_addr                   ),
    .rvfi_rs2_addr               (u_opensoc_top.rvfi_rs2_addr                   ),
    .rvfi_rs3_addr               (u_opensoc_top.rvfi_rs3_addr                   ),
    .rvfi_rs1_rdata              (u_opensoc_top.rvfi_rs1_rdata                  ),
    .rvfi_rs2_rdata              (u_opensoc_top.rvfi_rs2_rdata                  ),
    .rvfi_rs3_rdata              (u_opensoc_top.rvfi_rs3_rdata                  ),
    .rvfi_rd_addr                (u_opensoc_top.rvfi_rd_addr                    ),
    .rvfi_rd_wdata               (u_opensoc_top.rvfi_rd_wdata                   ),
    .rvfi_pc_rdata               (u_opensoc_top.rvfi_pc_rdata                   ),
    .rvfi_pc_wdata               (u_opensoc_top.rvfi_pc_wdata                   ),
    .rvfi_mem_addr               (u_opensoc_top.rvfi_mem_addr                   ),
    .rvfi_mem_rmask              (u_opensoc_top.rvfi_mem_rmask                  ),
    .rvfi_mem_wmask              (u_opensoc_top.rvfi_mem_wmask                  ),
    .rvfi_mem_rdata              (u_opensoc_top.rvfi_mem_rdata                  ),
    .rvfi_mem_wdata              (u_opensoc_top.rvfi_mem_wdata                  ),
    .rvfi_ext_expanded_insn_valid(u_opensoc_top.rvfi_ext_expanded_insn_valid    ),
    .rvfi_ext_expanded_insn      (u_opensoc_top.rvfi_ext_expanded_insn          )
  );
`endif

  export "DPI-C" function mhpmcounter_num;

  function automatic int unsigned mhpmcounter_num();
    return u_opensoc_top.u_top.u_ibex_core.cs_registers_i.MHPMCounterNum;
  endfunction

  export "DPI-C" function mhpmcounter_get;

  function automatic longint unsigned mhpmcounter_get(int index);
    return u_opensoc_top.u_top.u_ibex_core.cs_registers_i.mhpmcounter[index];
  endfunction

endmodule

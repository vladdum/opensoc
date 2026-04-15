// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FPGA top-level wrapper for Xilinx Kria KV260 (Zynq UltraScale+ ZU5EV)
//
// Clock: Zynq PS pl_clk0 → BUFG → system clock
// Reset: Zynq PS pl_resetn0 (active-low) → 3-FF synchronizer → rst_n
// Fan:   fan_en_b tied low (active-low always-on)
//
// Pin mapping:
//   HDA [G11]   ↔ I2C SCL  — open-drain (external pullup required)
//   HDA [F10]   ↔ I2C SDA  — open-drain (external pullup required)
//   Pmod1 [5:0] ↔ GPIO     — bidirectional with OE
//   LED[3:0]    ← gpio_o[3:0]
//   UART TX/RX  ↔ uart_tx / uart_rx

module opensoc_fpga_kv260_top (
  output logic        fan_en_b,

  output logic [3:0]  led,

  output logic        uart_tx,
  input  logic        uart_rx,

  inout  wire         i2c_scl,
  inout  wire         i2c_sda,

  inout  wire  [5:0]  gpio
);

  // -------------------------------------------------------------------------
  // PS block: provides pl_clk0 and pl_resetn0
  // -------------------------------------------------------------------------
  logic pl_clk0_raw;
  logic pl_rst_n_raw;

  zynq_ultra_ps_e_0 ps_i (
    .pl_clk0    (pl_clk0_raw),
    .pl_resetn0 (pl_rst_n_raw)
  );

  // -------------------------------------------------------------------------
  // Clock: buffer PL clock through BUFG
  // -------------------------------------------------------------------------
  logic clk_i;

  BUFG clk_buf_i (
    .I (pl_clk0_raw),
    .O (clk_i)
  );

  // -------------------------------------------------------------------------
  // Reset: async assert on !pl_rst_n_raw, synchronous deassertion on clk_i
  // -------------------------------------------------------------------------
  logic [2:0] rst_sync_q;
  logic rst_n;

  always_ff @(posedge clk_i or negedge pl_rst_n_raw) begin
    if (!pl_rst_n_raw) rst_sync_q <= 3'b000;
    else               rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end
  assign rst_n = rst_sync_q[2];

  // -------------------------------------------------------------------------
  // Fan: active-low enable, tied permanently on to prevent thermal shutdown
  // -------------------------------------------------------------------------
  assign fan_en_b = 1'b0;

  // -------------------------------------------------------------------------
  // GPIO
  // -------------------------------------------------------------------------
  logic [31:0] gpio_i_soc, gpio_o_soc, gpio_oe_soc;

  // Outputs: green LEDs [3:0]
  assign led = gpio_o_soc[3:0];

  // Upper inputs not driven by board hardware
  assign gpio_i_soc[31:22] = '0;

  // Bidirectional GPIO[5:0] on Pmod (gpio_o/gpio_oe bits [21:16])
  genvar gi;
  for (gi = 0; gi < 6; gi++) begin : gen_gpio_pmod
    assign gpio[gi]             = gpio_oe_soc[16 + gi] ? gpio_o_soc[16 + gi] : 1'bz;
    assign gpio_i_soc[16 + gi]  = gpio[gi];
  end

  // gpio_i bits [15:0] unused (no switches/buttons on KV260 PL side)
  assign gpio_i_soc[15:0] = '0;

  // -------------------------------------------------------------------------
  // I2C open-drain: drive low when OE asserted, tristate otherwise
  // -------------------------------------------------------------------------
  logic i2c_scl_o, i2c_scl_oe, i2c_scl_i;
  logic i2c_sda_o, i2c_sda_oe, i2c_sda_i;

  assign i2c_scl = i2c_scl_oe ? 1'b0 : 1'bz;
  assign i2c_sda = i2c_sda_oe ? 1'b0 : 1'bz;

  assign i2c_scl_i = i2c_scl;
  assign i2c_sda_i = i2c_sda;

  // -------------------------------------------------------------------------
  // SoC instance — config comes from opensoc_config_pkg (no parameters)
  // -------------------------------------------------------------------------
  opensoc_top soc_i (
    .IO_CLK    (clk_i),
    .IO_RST_N  (rst_n),

    .uart_tx_o (uart_tx),
    .uart_rx_i (uart_rx),

    .gpio_i    (gpio_i_soc),
    .gpio_o    (gpio_o_soc),
    .gpio_oe   (gpio_oe_soc),

    .i2c_scl_o (i2c_scl_o),
    .i2c_scl_oe(i2c_scl_oe),
    .i2c_scl_i (i2c_scl_i),
    .i2c_sda_o (i2c_sda_o),
    .i2c_sda_oe(i2c_sda_oe),
    .i2c_sda_i (i2c_sda_i)
  );

endmodule

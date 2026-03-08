// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Dual-SoC UART Communication Wrapper
 *
 * Instantiates two opensoc_top instances with cross-wired UART lines:
 *   u_soc0.uart_tx_o → u_soc1.uart_rx_i
 *   u_soc1.uart_tx_o → u_soc0.uart_rx_i
 *
 * Each SoC has its own RAM loaded with a different program.
 * GPIO and I2C pins are tied off.
 */

module opensoc_dual_uart (
  input IO_CLK,
  input IO_RST_N
);

  parameter SRAMInitFile = "";

  // UART cross-wiring signals
  logic soc0_uart_tx, soc1_uart_tx;

  // Unused GPIO/I2C outputs
  logic [31:0] soc0_gpio_o,  soc1_gpio_o;
  logic [31:0] soc0_gpio_oe, soc1_gpio_oe;
  logic soc0_i2c_scl_o,  soc1_i2c_scl_o;
  logic soc0_i2c_scl_oe, soc1_i2c_scl_oe;
  logic soc0_i2c_sda_o,  soc1_i2c_sda_o;
  logic soc0_i2c_sda_oe, soc1_i2c_sda_oe;

  opensoc_top #(
    .SRAMInitFile (SRAMInitFile)
  ) u_soc0 (
    .IO_CLK    (IO_CLK),
    .IO_RST_N  (IO_RST_N),

    // UART: TX out, RX from soc1
    .uart_tx_o (soc0_uart_tx),
    .uart_rx_i (soc1_uart_tx),

    // GPIO tied off
    .gpio_i    (32'b0),
    .gpio_o    (soc0_gpio_o),
    .gpio_oe   (soc0_gpio_oe),

    // I2C tied off (open-drain idle = high)
    .i2c_scl_o  (soc0_i2c_scl_o),
    .i2c_scl_oe (soc0_i2c_scl_oe),
    .i2c_scl_i  (1'b1),
    .i2c_sda_o  (soc0_i2c_sda_o),
    .i2c_sda_oe (soc0_i2c_sda_oe),
    .i2c_sda_i  (1'b1)
  );

  opensoc_top #(
    .SRAMInitFile (SRAMInitFile)
  ) u_soc1 (
    .IO_CLK    (IO_CLK),
    .IO_RST_N  (IO_RST_N),

    // UART: TX out, RX from soc0
    .uart_tx_o (soc1_uart_tx),
    .uart_rx_i (soc0_uart_tx),

    // GPIO tied off
    .gpio_i    (32'b0),
    .gpio_o    (soc1_gpio_o),
    .gpio_oe   (soc1_gpio_oe),

    // I2C tied off (open-drain idle = high)
    .i2c_scl_o  (soc1_i2c_scl_o),
    .i2c_scl_oe (soc1_i2c_scl_oe),
    .i2c_scl_i  (1'b1),
    .i2c_sda_o  (soc1_i2c_sda_o),
    .i2c_sda_oe (soc1_i2c_sda_oe),
    .i2c_sda_i  (1'b1)
  );

endmodule

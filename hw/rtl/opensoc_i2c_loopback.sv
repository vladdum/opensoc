// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * I2C Loopback Wrapper
 *
 * Instantiates opensoc_top and bridges the HW I2C master pins with PIO GPIO
 * pins using open-drain wired-AND logic, enabling a PIO I2C slave to
 * communicate with the hardware I2C controller.
 *
 * Pin assignment: gpio[0] = SDA, gpio[1] = SCL (matches i2c.pio.h)
 *
 * Open-drain bus model:
 *   Both I2C controller and PIO keep output values at 0.
 *   OE=1 pulls the line low; OE=0 releases it (floats high via pull-up).
 *   Bus = HIGH when neither side drives (AND of all released signals).
 */

module opensoc_i2c_loopback (
  input IO_CLK,
  input IO_RST_N
);

  parameter SRAMInitFile = "";

  // Internal signals from opensoc_top
  wire        i2c_scl_o, i2c_scl_oe, i2c_sda_o, i2c_sda_oe;
  wire [31:0] gpio_o, gpio_oe;
  wire        uart_tx;

  // Open-drain wired-AND: bus is HIGH unless someone pulls low (asserts OE)
  wire sda_bus = ~i2c_sda_oe & ~gpio_oe[0];
  wire scl_bus = ~i2c_scl_oe & ~gpio_oe[1];

  // GPIO input: I2C bus on pins [1:0], rest zero
  wire [31:0] gpio_i = {30'd0, scl_bus, sda_bus};

  opensoc_top #(
    .SRAMInitFile (SRAMInitFile)
  ) u_soc (
    .IO_CLK    (IO_CLK),
    .IO_RST_N  (IO_RST_N),

    .uart_tx_o (uart_tx),
    .uart_rx_i (1'b1),         // UART idle

    .gpio_i    (gpio_i),
    .gpio_o    (gpio_o),
    .gpio_oe   (gpio_oe),

    .i2c_scl_o  (i2c_scl_o),
    .i2c_scl_oe (i2c_scl_oe),
    .i2c_scl_i  (scl_bus),
    .i2c_sda_o  (i2c_sda_o),
    .i2c_sda_oe (i2c_sda_oe),
    .i2c_sda_i  (sda_bus)
  );

endmodule

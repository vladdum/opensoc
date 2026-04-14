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

endmodule

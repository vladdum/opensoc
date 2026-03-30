// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FPGA top-level wrapper for Digilent Arty A7-100T (Xilinx Artix-7 XC7A100T)
//
// Clock: 100 MHz board oscillator → PLL → 50 MHz system clock
// RAM:   512 KB block RAM (131072 × 32-bit words)
//
// Pin mapping:
//   LED[3:0]   ← gpio_o[3:0]         — green LEDs LD0-LD3 (active-high)
//   SW[3:0]    → gpio_i[3:0]         — slide switches SW0-SW3
//   BTN[2:0]   → gpio_i[6:4]         — push buttons BTN0-BTN2
//   Pmod JA[0] ↔ I2C SDA             — open-drain (external pullup required)
//   Pmod JA[1] ↔ I2C SCL             — open-drain (external pullup required)
//   Pmod JA[2..7] / gpio_i[23:16] ↔ gpio[23:16] — bidirectional with OE
//   USB-UART   ↔ UART TX/RX          — FTDI bridge on board
//   BTN3 (RESET) → reset             — active-high, inverted internally

module opensoc_fpga_arty_a7_top (
  input  CLK100MHZ,

  // Buttons (active-high)
  input  [3:0] btn,            // btn[3] = reset, btn[2:0] = GPIO inputs

  // Slide switches
  input  [3:0] sw,

  // Green LEDs
  output [3:0] led,

  // USB-UART (names match Arty A7 XDC convention)
  output uart_rxd_out,         // FPGA TX → USB-UART bridge RX
  input  uart_txd_in,          // USB-UART bridge TX → FPGA RX

  // Pmod JA — I2C (open-drain, needs external pullups)
  inout  [1:0] ja_i2c,         // ja_i2c[0] = SDA, ja_i2c[1] = SCL

  // Pmod JD — GPIO / PIO
  inout  [7:0] jd
);

  // -------------------------------------------------------------------------
  // Clock generation: 100 MHz → 50 MHz via PLL
  // -------------------------------------------------------------------------
  logic clk_50_unbuf, clk_50;
  logic clk_fb_unbuf, clk_fb;
  logic pll_locked;
  logic io_clk_buf;

  IBUF u_ibuf_clk (
    .I (CLK100MHZ),
    .O (io_clk_buf)
  );

  PLLE2_ADV #(
    .BANDWIDTH          ("OPTIMIZED"),
    .COMPENSATION       ("ZHOLD"),
    .STARTUP_WAIT       ("FALSE"),
    .DIVCLK_DIVIDE      (1),
    .CLKFBOUT_MULT      (12),       // VCO = 100 × 12 = 1200 MHz
    .CLKFBOUT_PHASE     (0.000),
    .CLKOUT0_DIVIDE     (24),       // 1200 / 24 = 50 MHz
    .CLKOUT0_PHASE      (0.000),
    .CLKOUT0_DUTY_CYCLE (0.500),
    .CLKIN1_PERIOD       (10.000)    // 100 MHz = 10 ns
  ) u_pll (
    .CLKFBOUT (clk_fb_unbuf),
    .CLKOUT0  (clk_50_unbuf),
    .CLKOUT1  (),
    .CLKOUT2  (),
    .CLKOUT3  (),
    .CLKOUT4  (),
    .CLKOUT5  (),
    .CLKFBIN  (clk_fb),
    .CLKIN1   (io_clk_buf),
    .CLKIN2   (1'b0),
    .CLKINSEL (1'b1),
    .DADDR    (7'h0),
    .DCLK     (1'b0),
    .DEN      (1'b0),
    .DI       (16'h0),
    .DO       (),
    .DRDY     (),
    .DWE      (1'b0),
    .LOCKED   (pll_locked),
    .PWRDWN   (1'b0),
    .RST      (1'b0)
  );

  BUFG u_bufg_fb  (.I(clk_fb_unbuf),  .O(clk_fb));
  BUFG u_bufg_clk (.I(clk_50_unbuf),  .O(clk_50));

  // -------------------------------------------------------------------------
  // Reset: active-high btn[3] + PLL lock → synchronous deassertion
  // -------------------------------------------------------------------------
  logic rst_raw_n;
  logic [2:0] rst_sync_q;
  logic rst_n;

  assign rst_raw_n = pll_locked & ~btn[3];

  always_ff @(posedge clk_50 or negedge rst_raw_n) begin
    if (!rst_raw_n) rst_sync_q <= 3'b000;
    else            rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end
  assign rst_n = rst_sync_q[2];

  // -------------------------------------------------------------------------
  // GPIO
  // -------------------------------------------------------------------------
  logic [31:0] gpio_i, gpio_o, gpio_oe;

  // Inputs: switches [3:0], buttons [2:0]
  assign gpio_i[3:0]   = sw;
  assign gpio_i[6:4]   = btn[2:0];
  assign gpio_i[15:7]  = '0;
  assign gpio_i[31:24] = '0;

  // Outputs: green LEDs [3:0]
  assign led = gpio_o[3:0];

  // -------------------------------------------------------------------------
  // Bidirectional GPIO on Pmod JD (gpio_o[23:16] with gpio_oe[23:16])
  // -------------------------------------------------------------------------
  genvar gi;
  for (gi = 0; gi < 8; gi++) begin : gen_gpio_jd
    assign jd[gi]         = gpio_oe[16 + gi] ? gpio_o[16 + gi] : 1'bz;
    assign gpio_i[16 + gi] = jd[gi];
  end

  // -------------------------------------------------------------------------
  // I2C open-drain: drive low when OE asserted, tristate otherwise
  // -------------------------------------------------------------------------
  logic i2c_scl_o, i2c_scl_oe, i2c_scl_i;
  logic i2c_sda_o, i2c_sda_oe, i2c_sda_i;

  assign ja_i2c[0] = i2c_sda_oe ? 1'b0 : 1'bz;
  assign ja_i2c[1] = i2c_scl_oe ? 1'b0 : 1'bz;

  assign i2c_sda_i = ja_i2c[0];
  assign i2c_scl_i = ja_i2c[1];

  // -------------------------------------------------------------------------
  // SoC instance — no parameter overrides; config comes from opensoc_config_pkg
  // -------------------------------------------------------------------------
  opensoc_top u_soc (
    .IO_CLK    (clk_50),
    .IO_RST_N  (rst_n),

    .uart_tx_o (uart_rxd_out),
    .uart_rx_i (uart_txd_in),

    .gpio_i    (gpio_i),
    .gpio_o    (gpio_o),
    .gpio_oe   (gpio_oe),

    .i2c_scl_o (i2c_scl_o),
    .i2c_scl_oe(i2c_scl_oe),
    .i2c_scl_i (i2c_scl_i),
    .i2c_sda_o (i2c_sda_o),
    .i2c_sda_oe(i2c_sda_oe),
    .i2c_sda_i (i2c_sda_i)
  );

endmodule

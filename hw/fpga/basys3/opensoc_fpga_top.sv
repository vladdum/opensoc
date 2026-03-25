// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FPGA top-level wrapper for Digilent Basys 3 (Xilinx Artix-7 XC7A35T)
//
// Clock: 100 MHz board oscillator → PLL → 50 MHz system clock
// RAM:   64 KB block RAM (16384 × 32-bit words)
//
// Pin mapping:
//   LED[15:0]  ← gpio_o[15:0]        — directly driven (active-high)
//   SW[15:0]   → gpio_i[15:0]        — directly sampled
//   Pmod JB    ↔ gpio[23:16]         — bidirectional with output enable
//   Pmod JA[0] ↔ I2C SDA             — open-drain (external pullup required)
//   Pmod JA[1] ↔ I2C SCL             — open-drain (external pullup required)
//   USB-UART   ↔ UART TX/RX          — directly connected to FTDI bridge
//   btnC       → reset               — active-high, inverted internally

module opensoc_fpga_top import axi_pkg::*; (
  input  CLK100MHZ,

  // Buttons
  input  btnC,             // center button → system reset (active-high)

  // Switches
  input  [15:0] sw,

  // LEDs
  output [15:0] led,

  // USB-UART (names match Basys 3 XDC convention)
  output uart_rxd_out,     // FPGA TX → USB-UART bridge RX
  input  uart_txd_in,      // USB-UART bridge TX → FPGA RX

  // Pmod JA — I2C (open-drain, needs external pullups)
  inout  [1:0] ja,         // ja[0] = SDA, ja[1] = SCL

  // Pmod JB — GPIO / PIO
  inout  [7:0] jb
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
  // Reset: active-high button + PLL lock → synchronous deassertion
  // -------------------------------------------------------------------------
  logic rst_raw_n;
  logic [2:0] rst_sync_q;
  logic rst_n;

  assign rst_raw_n = pll_locked & ~btnC;

  // 3-FF synchronizer: async assert, synchronous deassert
  always_ff @(posedge clk_50 or negedge rst_raw_n) begin
    if (!rst_raw_n)
      rst_sync_q <= 3'b000;
    else
      rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end

  assign rst_n = rst_sync_q[2];

  // -------------------------------------------------------------------------
  // GPIO wiring
  // -------------------------------------------------------------------------
  logic [31:0] gpio_o, gpio_oe, gpio_i;

  // Switches → gpio input [15:0]
  assign gpio_i[15:0] = sw;

  // Pmod JB ↔ gpio [23:16] (bidirectional with tristate)
  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : gen_pmod_jb
      assign jb[g]        = gpio_oe[16+g] ? gpio_o[16+g] : 1'bz;
      assign gpio_i[16+g] = jb[g];
    end
  endgenerate
  assign gpio_i[31:24] = 8'b0;

  // LEDs ← gpio output [15:0] (directly driven, no tristate)
  assign led = gpio_o[15:0];

  // -------------------------------------------------------------------------
  // I2C — open-drain on Pmod JA (external pullups required)
  // -------------------------------------------------------------------------
  logic i2c_sda_o, i2c_sda_oe, i2c_sda_i;
  logic i2c_scl_o, i2c_scl_oe, i2c_scl_i;

  // Drive low when OE=1 (open-drain); tristate (pulled high) when OE=0
  assign ja[0] = i2c_sda_oe ? 1'b0 : 1'bz;
  assign ja[1] = i2c_scl_oe ? 1'b0 : 1'bz;

  // Read back bus state
  assign i2c_sda_i = ja[0];
  assign i2c_scl_i = ja[1];

  // -------------------------------------------------------------------------
  // SoC instance
  // -------------------------------------------------------------------------
  opensoc_top #(
    .RamDepth        (16384),   // 64 KB (16384 × 4 bytes)
    .SRAMInitFile    (""),
    .EnableReLU      (1'b0),
    .EnableVMAC      (1'b0),
    .EnableSgDma     (1'b0),
    .EnableSoftmax   (1'b0),
    .XbarLatencyMode (axi_pkg::CUT_ALL_PORTS)
  ) u_soc (
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

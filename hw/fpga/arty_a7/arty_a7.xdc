# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Pin constraints for Digilent Arty A7-100T (XC7A100T-1CSG324C)
# Based on the official Digilent Arty A7 Master XDC
# https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-100-Master.xdc

# ==============================================================================
# System clock — 100 MHz
# ==============================================================================
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports CLK100MHZ]

# ==============================================================================
# Buttons (active-high)
# ==============================================================================
# btn[3] = RESET (BTN3, top)
set_property -dict { PACKAGE_PIN D9  IOSTANDARD LVCMOS33 } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN C9  IOSTANDARD LVCMOS33 } [get_ports {btn[1]}]
set_property -dict { PACKAGE_PIN B9  IOSTANDARD LVCMOS33 } [get_ports {btn[2]}]
set_property -dict { PACKAGE_PIN B8  IOSTANDARD LVCMOS33 } [get_ports {btn[3]}]

# ==============================================================================
# Slide switches
# ==============================================================================
set_property -dict { PACKAGE_PIN A8  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN C10 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN A10 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]

# ==============================================================================
# Green LEDs (LD0-LD3)
# ==============================================================================
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

# ==============================================================================
# USB-UART (via FTDI FT2232HQ)
# ==============================================================================
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]
set_property -dict { PACKAGE_PIN A9  IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]

# ==============================================================================
# Pmod JA — I2C (open-drain, external pullup required)
# JA1 = SDA (ja_i2c[0]), JA2 = SCL (ja_i2c[1])
# ==============================================================================
set_property -dict { PACKAGE_PIN G13 IOSTANDARD LVCMOS33 } [get_ports {ja_i2c[0]}]
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports {ja_i2c[1]}]

# ==============================================================================
# Pmod JD — GPIO / PIO (8 bidirectional pins)
# ==============================================================================
set_property -dict { PACKAGE_PIN D4  IOSTANDARD LVCMOS33 } [get_ports {jd[0]}]
set_property -dict { PACKAGE_PIN D3  IOSTANDARD LVCMOS33 } [get_ports {jd[1]}]
set_property -dict { PACKAGE_PIN F4  IOSTANDARD LVCMOS33 } [get_ports {jd[2]}]
set_property -dict { PACKAGE_PIN F3  IOSTANDARD LVCMOS33 } [get_ports {jd[3]}]
set_property -dict { PACKAGE_PIN E2  IOSTANDARD LVCMOS33 } [get_ports {jd[4]}]
set_property -dict { PACKAGE_PIN D2  IOSTANDARD LVCMOS33 } [get_ports {jd[5]}]
set_property -dict { PACKAGE_PIN H2  IOSTANDARD LVCMOS33 } [get_ports {jd[6]}]
set_property -dict { PACKAGE_PIN G2  IOSTANDARD LVCMOS33 } [get_ports {jd[7]}]

# ==============================================================================
# Bitstream configuration
# ==============================================================================
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

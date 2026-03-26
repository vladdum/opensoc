# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# SDC timing constraints for OpenSoC ASIC synthesis (Sky130)
# Target: 50 MHz (20 ns period)

# ----------------------------------------------------------------------
# Clock
# ----------------------------------------------------------------------
create_clock -name clk -period 20.0 [get_ports IO_CLK]
set_clock_uncertainty 0.5 [get_clocks clk]

# ----------------------------------------------------------------------
# Reset
# ----------------------------------------------------------------------
set_input_delay  5.0 -clock clk [get_ports IO_RST_N]
set_false_path -from [get_ports IO_RST_N]

# ----------------------------------------------------------------------
# UART
# ----------------------------------------------------------------------
set_input_delay  5.0 -clock clk [get_ports uart_rx_i]
set_output_delay 5.0 -clock clk [get_ports uart_tx_o]

# ----------------------------------------------------------------------
# GPIO
# ----------------------------------------------------------------------
set_input_delay  5.0 -clock clk [get_ports {gpio_i[*]}]
set_output_delay 5.0 -clock clk [get_ports {gpio_o[*]}]
set_output_delay 5.0 -clock clk [get_ports {gpio_oe[*]}]

# ----------------------------------------------------------------------
# I2C (open-drain: low-speed, generous margins)
# ----------------------------------------------------------------------
set_input_delay  8.0 -clock clk [get_ports {i2c_scl_i i2c_sda_i}]
set_output_delay 8.0 -clock clk [get_ports {i2c_scl_o i2c_scl_oe i2c_sda_o i2c_sda_oe}]

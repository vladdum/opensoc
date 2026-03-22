## Digilent Basys 3 — Xilinx Artix-7 XC7A35T-1CPG236C
## Pin constraints for opensoc_fpga_top

## ----------------------------------------------------------------------------
## Clock — 100 MHz oscillator (W5)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports CLK100MHZ]

## ----------------------------------------------------------------------------
## Reset — center button (active-high)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports btnC]

## ----------------------------------------------------------------------------
## Switches (SW0–SW15)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN V2  IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN T3  IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN T2  IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN R3  IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN T1  IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33} [get_ports {sw[15]}]

## ----------------------------------------------------------------------------
## LEDs (LD0–LD15)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports {led[15]}]

## ----------------------------------------------------------------------------
## USB-UART (FTDI FT2232HQ bridge)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports uart_txd_in]

## ----------------------------------------------------------------------------
## Pmod JA — I2C (external pullups required)
##   ja[0] = SDA (pin 1 of Pmod JA = FPGA J1)
##   ja[1] = SCL (pin 2 of Pmod JA = FPGA L2)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {ja[0]}]
set_property -dict {PACKAGE_PIN L2 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {ja[1]}]

## ----------------------------------------------------------------------------
## Pmod JB — GPIO / PIO [7:0]
##   jb[0]–jb[3] = top row  (pins 1–4)
##   jb[4]–jb[7] = bottom row (pins 7–10)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {jb[0]}]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports {jb[1]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports {jb[2]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports {jb[3]}]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports {jb[4]}]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS33} [get_ports {jb[5]}]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports {jb[6]}]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports {jb[7]}]

## ----------------------------------------------------------------------------
## Bitstream configuration
## ----------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

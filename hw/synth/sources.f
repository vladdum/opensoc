# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Shared source file list for FPGA and ASIC synthesis flows.
# Paths are relative to the FuseSoC build directory ($SRC_DIR).
# Sections: [includes], [packages], [rtl]
# Blank lines and '#' comments are ignored.

[includes]
lowrisc_prim_assert_0.1/rtl
lowrisc_prim_secded_0.1/rtl
lowrisc_prim_util_get_scramble_params_0/rtl
lowrisc_prim_util_memload_0/rtl
lowrisc_dv_dv_fcov_macros_0
pulp-platform.org__axi_0.39.9/include
pulp-platform.org__common_cells_1.39.0/include

[packages]
lowrisc_prim_generic_prim_pkg_0/rtl/prim_pkg.sv
lowrisc_prim_util_0.1/rtl/prim_util_pkg.sv
lowrisc_prim_generic_ram_1p_pkg_0/rtl/prim_ram_1p_pkg.sv
lowrisc_prim_generic_ram_2p_pkg_0/rtl/prim_ram_2p_pkg.sv
lowrisc_prim_generic_rom_pkg_0/rtl/prim_rom_pkg.sv
lowrisc_prim_pad_wrapper_pkg_0/rtl/prim_pad_wrapper_pkg.sv
lowrisc_prim_secded_0.1/rtl/prim_secded_pkg.sv
lowrisc_prim_mubi_pkg_0.1/rtl/prim_mubi_pkg.sv
lowrisc_prim_cipher_pkg_0.1/rtl/prim_cipher_pkg.sv
lowrisc_prim_count_0/rtl/prim_count_pkg.sv
lowrisc_ibex_ibex_pkg_0.1/rtl/ibex_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/cf_math_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/ecc_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/cb_filter_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/cdc_reset_ctrlr_pkg.sv
pulp-platform.org__axi_0.39.9/src/axi_pkg.sv
opensoc_soc_opensoc_top_0/hw/top/opensoc_config_pkg.sv
opensoc_soc_opensoc_top_0/hw/top/opensoc_derived_config_pkg.sv

[rtl]
lowrisc_prim_assert_0.1/rtl/prim_assert.sv
lowrisc_prim_assert_0.1/rtl/prim_flop_macros.sv
lowrisc_ibex_ibex_core_0.1/rtl/*.sv
lowrisc_ibex_ibex_icache_0.1/rtl/*.sv
lowrisc_ibex_ibex_top_0.1/rtl/*.sv
lowrisc_ibex_sim_shared_0/rtl/*.sv
lowrisc_ibex_sim_shared_0/rtl/sim/*.sv
lowrisc_prim_cdc_rand_delay_0/rtl/*.sv
lowrisc_prim_cipher_0/rtl/*.sv
lowrisc_prim_count_0/rtl/prim_count.sv
lowrisc_prim_generic_and2_0/rtl/*.sv
lowrisc_prim_generic_buf_0/rtl/*.sv
lowrisc_prim_generic_clock_buf_0/rtl/*.sv
lowrisc_prim_generic_clock_div_0/rtl/*.sv
lowrisc_prim_generic_clock_gating_0/rtl/*.sv
lowrisc_prim_generic_clock_inv_0/rtl/*.sv
lowrisc_prim_generic_clock_mux2_0/rtl/*.sv
lowrisc_prim_generic_flop_0/rtl/*.sv
lowrisc_prim_generic_flop_2sync_0/rtl/*.sv
lowrisc_prim_generic_flop_en_0/rtl/*.sv
lowrisc_prim_generic_flop_no_rst_0/rtl/*.sv
lowrisc_prim_generic_pad_attr_0/rtl/*.sv
lowrisc_prim_generic_pad_wrapper_0/rtl/*.sv
lowrisc_prim_generic_ram_1p_0/rtl/*.sv
lowrisc_prim_generic_ram_1r1w_0/rtl/*.sv
lowrisc_prim_generic_ram_2p_0/rtl/*.sv
lowrisc_prim_generic_rom_0/rtl/*.sv
lowrisc_prim_generic_rst_sync_0/rtl/*.sv
lowrisc_prim_generic_usb_diff_rx_0/rtl/*.sv
lowrisc_prim_generic_xnor2_0/rtl/*.sv
lowrisc_prim_generic_xor2_0/rtl/*.sv
lowrisc_prim_lfsr_0.1/rtl/*.sv
lowrisc_prim_mubi_0.1/rtl/*.sv
lowrisc_prim_onehot_0/rtl/*.sv
lowrisc_prim_onehot_check_0/rtl/*.sv
lowrisc_prim_ram_1p_adv_0.1/rtl/*.sv
lowrisc_prim_ram_1p_scr_0.1/rtl/*.sv
lowrisc_prim_sec_anchor_0.1/rtl/*.sv
lowrisc_prim_secded_0.1/rtl/*.sv
pulp-platform.org__axi_0.39.9/src/*.sv
pulp-platform.org__common_cells_1.39.0/src/*.sv
pulp-platform.org__common_cells_1.39.0/src/deprecated/*.sv
opensoc_ip_pio_0/rtl/*.sv
opensoc_ip_relu_accel_0/rtl/*.sv
opensoc_ip_sg_dma_0/rtl/*.sv
opensoc_ip_softmax_0/rtl/*.sv
opensoc_ip_vec_mac_0/rtl/*.sv
opensoc_ip_conv1d_0/rtl/conv1d_shift_reg.sv
opensoc_ip_conv1d_0/rtl/conv1d_pe.sv
opensoc_ip_conv1d_0/rtl/conv1d.sv
opensoc_ip_conv2d_0/rtl/line_buffer.sv
opensoc_ip_conv2d_0/rtl/conv2d_pe.sv
opensoc_ip_conv2d_0/rtl/addr_gen.sv
opensoc_ip_conv2d_0/rtl/conv2d.sv
opensoc_ip_ram_0/rtl/opensoc_ram.sv
opensoc_soc_opensoc_top_0/hw/top/opensoc_top.sv
opensoc_ip_uart_0/rtl/uart.sv
opensoc_ip_i2c_controller_0/rtl/i2c_controller.sv

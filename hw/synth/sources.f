# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Shared source file list for FPGA and ASIC synthesis flows.
# Paths are relative to the FuseSoC build directory ($SRC_DIR).
# Sections: [includes], [packages], [rtl]
# Blank lines and '#' comments are ignored.

[includes]
pulp-platform.org__axi_0.39.9/include
pulp-platform.org__common_cells_1.39.0/include

[packages]
pulp-platform.org__common_cells_1.39.0/src/cf_math_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/ecc_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/cb_filter_pkg.sv
pulp-platform.org__common_cells_1.39.0/src/cdc_reset_ctrlr_pkg.sv
pulp-platform.org__axi_0.39.9/src/axi_pkg.sv
opensoc_soc_opensoc_top_0/hw/top/opensoc_config_pkg.sv
opensoc_soc_opensoc_top_0/hw/top/opensoc_derived_config_pkg.sv

[rtl]
opensoc_ip_kronos_riscv_0/rtl/kronos_pkg.sv
# Kronos modules used by stage3: alu/regfile/csr from stage0, forward/hazard
# from stage1, decode/muldiv from stage2, everything else from stage3.
# Stage0/1/2 kronos_top.sv and kronos_lsu.sv are excluded to avoid duplicates.
opensoc_ip_kronos_riscv_0/rtl/stage0/kronos_alu.sv
opensoc_ip_kronos_riscv_0/rtl/stage0/kronos_regfile.sv
opensoc_ip_kronos_riscv_0/rtl/stage0/kronos_csr.sv
opensoc_ip_kronos_riscv_0/rtl/stage1/kronos_forward.sv
opensoc_ip_kronos_riscv_0/rtl/stage1/kronos_hazard.sv
opensoc_ip_kronos_riscv_0/rtl/stage2/kronos_decode.sv
opensoc_ip_kronos_riscv_0/rtl/stage2/kronos_muldiv.sv
opensoc_ip_kronos_riscv_0/rtl/stage3/*.sv
opensoc_ip_sim_shared_0/*.sv
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
opensoc_ip_gemm_0/rtl/pe_cell.sv
opensoc_ip_gemm_0/rtl/data_skew.sv
opensoc_ip_gemm_0/rtl/systolic_array.sv
opensoc_ip_gemm_0/rtl/result_drain.sv
opensoc_ip_gemm_0/rtl/gemm.sv
opensoc_ip_ram_0/rtl/opensoc_ram.sv
opensoc_soc_opensoc_top_0/hw/top/opensoc_top.sv
opensoc_ip_uart_0/rtl/uart.sv
opensoc_ip_i2c_controller_0/rtl/i2c_controller.sv

# sw/tests/tests.mk — Test registry
#
# Single source of truth for all SW tests. Included by the root Makefile.
# To add a test:
#   1. Create sw/tests/<name>_test/ with a Makefile and source file.
#   2. Add SW_DIR_<slug>, ELF_<slug> entries below.
#   3. Add the slug to REGRESSION_TESTS (with any ENABLE_* guard) and RUN_TESTS.
#
# Slug conventions: underscores in directory names become hyphens in slugs
# (e.g. sg_dma_test → sg-dma, conv1d_relu_stream_test → conv1d-relu-stream).

SW_BUILD_DIR ?= build/sw
SW_TEST_DIR  ?= sw/tests

# ---------------------------------------------------------------------------
# Source directories and ELF paths
# ---------------------------------------------------------------------------

SW_DIR_hello             := $(SW_TEST_DIR)/hello_test
SW_DIR_uart              := $(SW_TEST_DIR)/uart_test
SW_DIR_pio               := $(SW_TEST_DIR)/pio_test
SW_DIR_pio-sdk           := $(SW_TEST_DIR)/pio_sdk_test
SW_DIR_pio-i2c           := $(SW_TEST_DIR)/pio_i2c_test
SW_DIR_i2c               := $(SW_TEST_DIR)/i2c_test
SW_DIR_relu              := $(SW_TEST_DIR)/relu_test
SW_DIR_vmac              := $(SW_TEST_DIR)/vmac_test
SW_DIR_sg-dma            := $(SW_TEST_DIR)/sg_dma_test
SW_DIR_softmax           := $(SW_TEST_DIR)/softmax_test
SW_DIR_aes               := $(SW_TEST_DIR)/aes_test
SW_DIR_conv1d            := $(SW_TEST_DIR)/conv1d_test
SW_DIR_conv1d-relu-stream:= $(SW_TEST_DIR)/conv1d_relu_stream_test
SW_DIR_conv2d                    := $(SW_TEST_DIR)/conv2d_test
SW_DIR_conv2d-relu-softmax-stream:= $(SW_TEST_DIR)/conv2d_relu_softmax_stream_test
SW_DIR_gemm                      := $(SW_TEST_DIR)/gemm_test
SW_DIR_i2c-loopback      := $(SW_TEST_DIR)/i2c_loopback_test

ELF_hello             := $(SW_BUILD_DIR)/hello_test/hello_test.elf
ELF_uart              := $(SW_BUILD_DIR)/uart_test/uart_test.elf
ELF_pio               := $(SW_BUILD_DIR)/pio_test/pio_test.elf
ELF_pio-sdk           := $(SW_BUILD_DIR)/pio_sdk_test/pio_sdk_test.elf
ELF_pio-i2c           := $(SW_BUILD_DIR)/pio_i2c_test/pio_i2c_test.elf
ELF_i2c               := $(SW_BUILD_DIR)/i2c_test/i2c_test.elf
ELF_relu              := $(SW_BUILD_DIR)/relu_test/relu_test.elf
ELF_vmac              := $(SW_BUILD_DIR)/vmac_test/vmac_test.elf
ELF_sg-dma            := $(SW_BUILD_DIR)/sg_dma_test/sg_dma_test.elf
ELF_softmax           := $(SW_BUILD_DIR)/softmax_test/softmax_test.elf
ELF_aes               := $(SW_BUILD_DIR)/aes_test/aes_test.elf
ELF_conv1d            := $(SW_BUILD_DIR)/conv1d_test/conv1d_test.elf
ELF_conv1d-relu-stream:= $(SW_BUILD_DIR)/conv1d_relu_stream_test/conv1d_relu_stream_test.elf
ELF_conv2d                    := $(SW_BUILD_DIR)/conv2d_test/conv2d_test.elf
ELF_conv2d-relu-softmax-stream:= $(SW_BUILD_DIR)/conv2d_relu_softmax_stream_test/conv2d_relu_softmax_stream_test.elf
ELF_gemm                      := $(SW_BUILD_DIR)/gemm_test/gemm_test.elf
ELF_i2c-loopback      := $(SW_BUILD_DIR)/i2c_loopback_test/i2c_loopback_test.elf

# ---------------------------------------------------------------------------
# Per-test simulator flag overrides
# ---------------------------------------------------------------------------

# i2c-loopback needs more cycles for clock-stretching sequences
SIM_FLAGS_i2c-loopback := -c 500000

# ---------------------------------------------------------------------------
# Regression test lists
# ---------------------------------------------------------------------------

# Base: always run, no IP flags required
REGRESSION_BASE := hello uart pio pio-sdk pio-i2c i2c

# Conditional: included when the corresponding ENABLE_* flag(s) are set.
# i2c-loopback excluded pending fix — see issue #14.
REGRESSION_TESTS := $(REGRESSION_BASE)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_RELU)),relu)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_VMAC)),vmac)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_SGDMA)),sg-dma)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_SOFTMAX)),softmax)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_CRYPTO)),aes)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_CONV1D)),conv1d)
REGRESSION_TESTS += $(if $(and $(filter 1,$(ENABLE_CONV1D)),$(filter 1,$(ENABLE_RELU))),conv1d-relu-stream)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_CONV2D)),conv2d)
REGRESSION_TESTS += $(if $(and $(filter 1,$(ENABLE_CONV2D)),$(filter 1,$(ENABLE_RELU)),$(filter 1,$(ENABLE_SOFTMAX))),conv2d-relu-softmax-stream)
REGRESSION_TESTS += $(if $(filter 1,$(ENABLE_GEMM)),gemm)

# Full set — all IPs; used by regression-full and CI
REGRESSION_FULL_TESTS := $(REGRESSION_BASE) \
  relu vmac sg-dma softmax aes \
  conv1d conv1d-relu-stream \
  conv2d conv2d-relu-softmax-stream gemm

# run-* targets exposed to the user (bash-completable)
RUN_TESTS := \
  hello uart pio pio-sdk pio-i2c i2c \
  relu vmac sg-dma softmax aes \
  conv1d conv1d-relu-stream \
  conv2d conv2d-relu-softmax-stream gemm \
  i2c-loopback

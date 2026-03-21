// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenSoC compatibility layer for Pico SDK PIO API
// Provides hw_set_bits, hw_clear_bits, hw_xor_bits, and platform constants

#ifndef HARDWARE_PIO_COMPAT_H
#define HARDWARE_PIO_COMPAT_H

#include <stdint.h>
#include <stdbool.h>

// -----------------------------------------------------------------------
// Pico SDK type aliases
// -----------------------------------------------------------------------
#ifndef _UINT_T_DEFINED
#define _UINT_T_DEFINED
typedef unsigned int uint;
#endif

// -----------------------------------------------------------------------
// Platform constants
// -----------------------------------------------------------------------
#define PICO_NO_HARDWARE       0
#define SYSTEM_CLK_HZ          50000000u
#define NUM_PIO_STATE_MACHINES 4
#define NUM_PIOS               1
#define PIO_INSTRUCTION_COUNT  32

// -----------------------------------------------------------------------
// Pico SDK return codes
// -----------------------------------------------------------------------
#define PICO_OK                0
#define PICO_ERROR_GENERIC    -1

// -----------------------------------------------------------------------
// Atomic register helpers (read-modify-write on OpenSoC — no atomics)
// -----------------------------------------------------------------------
static inline void hw_set_bits(io_rw_32 *addr, uint32_t mask) {
    *addr = *addr | mask;
}

static inline void hw_clear_bits(io_rw_32 *addr, uint32_t mask) {
    *addr = *addr & ~mask;
}

static inline void hw_xor_bits(io_rw_32 *addr, uint32_t mask) {
    *addr = *addr ^ mask;
}

// -----------------------------------------------------------------------
// Pico SDK utility stubs
// -----------------------------------------------------------------------
static inline void tight_loop_contents(void) {
    // No WFE on Ibex — busy-wait is the only option
}

static inline unsigned bool_to_bit(bool b) {
    return b ? 1u : 0u;
}

// -----------------------------------------------------------------------
// GPIO stubs (no pad controller on OpenSoC)
// -----------------------------------------------------------------------
static inline void pio_gpio_init(void *pio, unsigned pin) {
    (void)pio;
    (void)pin;
    // No-op: OpenSoC pins are PIO-owned, no mux to configure
}

static inline void gpio_set_function(unsigned pin, unsigned fn) {
    (void)pin;
    (void)fn;
}

static inline void gpio_pull_up(unsigned pin) {
    (void)pin;
}

static inline void gpio_pull_down(unsigned pin) {
    (void)pin;
}

// -----------------------------------------------------------------------
// Clock stub
// -----------------------------------------------------------------------
#define clk_sys 0
static inline uint32_t clock_get_hz(unsigned clk_id) {
    (void)clk_id;
    return SYSTEM_CLK_HZ;
}

#endif // HARDWARE_PIO_COMPAT_H

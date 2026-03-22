// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pico SDK-compatible PIO API for OpenSoC
// Matches raspberrypi/pico-sdk hardware/pio.h function signatures
//
// Usage:
//   #include "hardware/pio.h"
//   uint offset = pio_add_program(pio0, &my_program);
//   uint sm = pio_claim_unused_sm(pio0, true);
//   pio_sm_config c = my_program_get_default_config(offset);
//   pio_sm_init(pio0, sm, offset, &c);
//   pio_sm_set_enabled(pio0, sm, true);

#ifndef HARDWARE_PIO_H
#define HARDWARE_PIO_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "hardware/structs/pio.h"
#include "hardware/pio_instructions.h"
#include "../hardware_pio_compat.h"

// Portable count-trailing-zeros (avoids _pio_ctz → __ctzsi2 on bare-metal)
static inline unsigned _pio_ctz(uint32_t v) {
    unsigned n = 0;
    if (v == 0) return 32;
    while ((v & 1u) == 0) { v >>= 1; n++; }
    return n;
}
#include "../../include/opensoc_regs.h"

// -----------------------------------------------------------------------
// PIO type and instance
// -----------------------------------------------------------------------
typedef volatile pio_hw_t *PIO;
#define pio0 ((PIO)PIO_BASE)

// -----------------------------------------------------------------------
// Enumerations
// -----------------------------------------------------------------------
enum pio_fifo_join {
    PIO_FIFO_JOIN_NONE = 0,
    PIO_FIFO_JOIN_TX   = 1,
    PIO_FIFO_JOIN_RX   = 2,
};

enum pio_mov_status_type {
    STATUS_TX_LESSTHAN = 0,
    STATUS_RX_LESSTHAN = 1,
};

// -----------------------------------------------------------------------
// SM config struct (built up locally, then applied atomically)
// -----------------------------------------------------------------------
typedef struct {
    uint32_t clkdiv;
    uint32_t execctrl;
    uint32_t shiftctrl;
    uint32_t pinctrl;
} pio_sm_config;

// -----------------------------------------------------------------------
// Program descriptor
// -----------------------------------------------------------------------
typedef struct pio_program {
    const uint16_t *instructions;
    uint8_t length;
    int8_t origin;       // -1 = relocatable, 0-31 = fixed
} pio_program_t;

// -----------------------------------------------------------------------
// Default config — matches Pico SDK defaults
// wrap=0..31, clkdiv=1.0, shift_right, no autopush/pull, threshold=32
// -----------------------------------------------------------------------
static inline pio_sm_config pio_get_default_sm_config(void) {
    pio_sm_config c;
    c.clkdiv    = 1u << PIO_SM0_CLKDIV_INT_LSB;  // INT=1, FRAC=0
    c.execctrl  = (31u << PIO_SM0_EXECCTRL_WRAP_TOP_LSB);  // wrap_top=31, wrap_bottom=0
    c.shiftctrl = (1u << PIO_SM0_SHIFTCTRL_IN_SHIFTDIR_LSB) |
                  (1u << PIO_SM0_SHIFTCTRL_OUT_SHIFTDIR_LSB);  // shift right
    c.pinctrl   = (5u << PIO_SM0_PINCTRL_SET_COUNT_LSB);  // set_count=5 (RP2040 default)
    return c;
}

// -----------------------------------------------------------------------
// Config builder functions
// -----------------------------------------------------------------------
static inline void sm_config_set_out_pins(pio_sm_config *c, unsigned out_base, unsigned out_count) {
    c->pinctrl = (c->pinctrl & ~(PIO_SM0_PINCTRL_OUT_BASE_BITS | PIO_SM0_PINCTRL_OUT_COUNT_BITS))
               | ((out_base << PIO_SM0_PINCTRL_OUT_BASE_LSB) & PIO_SM0_PINCTRL_OUT_BASE_BITS)
               | ((out_count << PIO_SM0_PINCTRL_OUT_COUNT_LSB) & PIO_SM0_PINCTRL_OUT_COUNT_BITS);
}

static inline void sm_config_set_set_pins(pio_sm_config *c, unsigned set_base, unsigned set_count) {
    c->pinctrl = (c->pinctrl & ~(PIO_SM0_PINCTRL_SET_BASE_BITS | PIO_SM0_PINCTRL_SET_COUNT_BITS))
               | ((set_base << PIO_SM0_PINCTRL_SET_BASE_LSB) & PIO_SM0_PINCTRL_SET_BASE_BITS)
               | ((set_count << PIO_SM0_PINCTRL_SET_COUNT_LSB) & PIO_SM0_PINCTRL_SET_COUNT_BITS);
}

static inline void sm_config_set_in_pins(pio_sm_config *c, unsigned in_base) {
    c->pinctrl = (c->pinctrl & ~PIO_SM0_PINCTRL_IN_BASE_BITS)
               | ((in_base << PIO_SM0_PINCTRL_IN_BASE_LSB) & PIO_SM0_PINCTRL_IN_BASE_BITS);
}

static inline void sm_config_set_sideset_pins(pio_sm_config *c, unsigned sideset_base) {
    c->pinctrl = (c->pinctrl & ~PIO_SM0_PINCTRL_SIDESET_BASE_BITS)
               | ((sideset_base << PIO_SM0_PINCTRL_SIDESET_BASE_LSB) & PIO_SM0_PINCTRL_SIDESET_BASE_BITS);
}

static inline void sm_config_set_sideset(pio_sm_config *c, unsigned bit_count,
                                          bool optional, bool pindirs) {
    c->pinctrl = (c->pinctrl & ~PIO_SM0_PINCTRL_SIDESET_COUNT_BITS)
               | ((bit_count << PIO_SM0_PINCTRL_SIDESET_COUNT_LSB) & PIO_SM0_PINCTRL_SIDESET_COUNT_BITS);
    c->execctrl = (c->execctrl & ~(PIO_SM0_EXECCTRL_SIDE_EN_BITS | PIO_SM0_EXECCTRL_SIDE_PINDIR_BITS))
                | (bool_to_bit(optional) << PIO_SM0_EXECCTRL_SIDE_EN_LSB)
                | (bool_to_bit(pindirs) << PIO_SM0_EXECCTRL_SIDE_PINDIR_LSB);
}

static inline void sm_config_set_clkdiv_int_frac8(pio_sm_config *c,
                                                    uint32_t div_int, uint8_t div_frac8) {
    c->clkdiv = ((uint32_t)div_frac8 << PIO_SM0_CLKDIV_FRAC_LSB)
              | (div_int << PIO_SM0_CLKDIV_INT_LSB);
}

static inline void sm_config_set_clkdiv(pio_sm_config *c, float div) {
    uint32_t div_int = (uint32_t)div;
    uint8_t div_frac8 = (uint8_t)((div - (float)div_int) * 256.0f);
    sm_config_set_clkdiv_int_frac8(c, div_int, div_frac8);
}

static inline void sm_config_set_wrap(pio_sm_config *c, unsigned wrap_target, unsigned wrap) {
    c->execctrl = (c->execctrl & ~(PIO_SM0_EXECCTRL_WRAP_TOP_BITS | PIO_SM0_EXECCTRL_WRAP_BOTTOM_BITS))
                | ((wrap_target << PIO_SM0_EXECCTRL_WRAP_BOTTOM_LSB) & PIO_SM0_EXECCTRL_WRAP_BOTTOM_BITS)
                | ((wrap << PIO_SM0_EXECCTRL_WRAP_TOP_LSB) & PIO_SM0_EXECCTRL_WRAP_TOP_BITS);
}

static inline void sm_config_set_jmp_pin(pio_sm_config *c, unsigned pin) {
    c->execctrl = (c->execctrl & ~PIO_SM0_EXECCTRL_JMP_PIN_BITS)
                | ((pin << PIO_SM0_EXECCTRL_JMP_PIN_LSB) & PIO_SM0_EXECCTRL_JMP_PIN_BITS);
}

static inline void sm_config_set_in_shift(pio_sm_config *c, bool shift_right,
                                           bool autopush, unsigned push_threshold) {
    c->shiftctrl = (c->shiftctrl & ~(PIO_SM0_SHIFTCTRL_IN_SHIFTDIR_BITS |
                                      PIO_SM0_SHIFTCTRL_AUTOPUSH_BITS |
                                      PIO_SM0_SHIFTCTRL_PUSH_THRESH_BITS))
                 | (bool_to_bit(shift_right) << PIO_SM0_SHIFTCTRL_IN_SHIFTDIR_LSB)
                 | (bool_to_bit(autopush) << PIO_SM0_SHIFTCTRL_AUTOPUSH_LSB)
                 | ((push_threshold & 0x1fu) << PIO_SM0_SHIFTCTRL_PUSH_THRESH_LSB);
}

static inline void sm_config_set_out_shift(pio_sm_config *c, bool shift_right,
                                            bool autopull, unsigned pull_threshold) {
    c->shiftctrl = (c->shiftctrl & ~(PIO_SM0_SHIFTCTRL_OUT_SHIFTDIR_BITS |
                                      PIO_SM0_SHIFTCTRL_AUTOPULL_BITS |
                                      PIO_SM0_SHIFTCTRL_PULL_THRESH_BITS))
                 | (bool_to_bit(shift_right) << PIO_SM0_SHIFTCTRL_OUT_SHIFTDIR_LSB)
                 | (bool_to_bit(autopull) << PIO_SM0_SHIFTCTRL_AUTOPULL_LSB)
                 | ((pull_threshold & 0x1fu) << PIO_SM0_SHIFTCTRL_PULL_THRESH_LSB);
}

static inline void sm_config_set_fifo_join(pio_sm_config *c, enum pio_fifo_join join) {
    c->shiftctrl = (c->shiftctrl & ~(PIO_SM0_SHIFTCTRL_FJOIN_TX_BITS | PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS))
                 | (((unsigned)join) << PIO_SM0_SHIFTCTRL_FJOIN_TX_LSB);
}

static inline void sm_config_set_mov_status(pio_sm_config *c,
                                             enum pio_mov_status_type status_sel,
                                             unsigned status_n) {
    c->execctrl = (c->execctrl & ~(PIO_SM0_EXECCTRL_STATUS_SEL_BITS | PIO_SM0_EXECCTRL_STATUS_N_BITS))
                | (((unsigned)status_sel) << PIO_SM0_EXECCTRL_STATUS_SEL_LSB)
                | ((status_n & 0xfu) << PIO_SM0_EXECCTRL_STATUS_N_LSB);
}

// -----------------------------------------------------------------------
// Static state (instruction memory and SM claim tracking)
// -----------------------------------------------------------------------
static uint32_t _pio_used_instruction_space = 0;  // bitmask of used slots
static uint8_t  _pio_sm_claimed = 0;               // bitmask of claimed SMs

// -----------------------------------------------------------------------
// SM enable / disable
// -----------------------------------------------------------------------
static inline void pio_sm_set_enabled(PIO pio, unsigned sm, bool enabled) {
    if (enabled) {
        pio->ctrl |= (1u << (PIO_CTRL_SM_ENABLE_LSB + sm));
    } else {
        pio->ctrl &= ~(1u << (PIO_CTRL_SM_ENABLE_LSB + sm));
    }
}

static inline void pio_set_sm_mask_enabled(PIO pio, uint32_t mask, bool enabled) {
    if (enabled) {
        pio->ctrl |= (mask & PIO_CTRL_SM_ENABLE_BITS);
    } else {
        pio->ctrl &= ~(mask & PIO_CTRL_SM_ENABLE_BITS);
    }
}

// -----------------------------------------------------------------------
// SM restart / clkdiv restart
// -----------------------------------------------------------------------
static inline void pio_sm_restart(PIO pio, unsigned sm) {
    hw_set_bits(&pio->ctrl, 1u << (PIO_CTRL_SM_RESTART_LSB + sm));
}

static inline void pio_sm_clkdiv_restart(PIO pio, unsigned sm) {
    hw_set_bits(&pio->ctrl, 1u << (PIO_CTRL_CLKDIV_RESTART_LSB + sm));
}

// -----------------------------------------------------------------------
// SM config apply
// -----------------------------------------------------------------------
static inline void pio_sm_set_config(PIO pio, unsigned sm, const pio_sm_config *config) {
    pio->sm[sm].clkdiv    = config->clkdiv;
    pio->sm[sm].execctrl  = config->execctrl;
    pio->sm[sm].shiftctrl = config->shiftctrl;
    pio->sm[sm].pinctrl   = config->pinctrl;
}

// -----------------------------------------------------------------------
// Forced instruction execution
// -----------------------------------------------------------------------
static inline void pio_sm_exec(PIO pio, unsigned sm, unsigned instr) {
    pio->sm[sm].instr = instr;
}

static inline bool pio_sm_is_exec_stalled(PIO pio, unsigned sm) {
    return (pio->sm[sm].execctrl & PIO_SM0_EXECCTRL_EXEC_STALLED_BITS) != 0;
}

static inline void pio_sm_exec_wait_blocking(PIO pio, unsigned sm, unsigned instr) {
    pio_sm_exec(pio, sm, instr);
    while (pio_sm_is_exec_stalled(pio, sm)) {
        tight_loop_contents();
    }
}

// -----------------------------------------------------------------------
// SM PC
// -----------------------------------------------------------------------
static inline uint8_t pio_sm_get_pc(PIO pio, unsigned sm) {
    return (uint8_t)(pio->sm[sm].addr & 0x1fu);
}

// -----------------------------------------------------------------------
// Clock divider
// -----------------------------------------------------------------------
static inline void pio_sm_set_clkdiv_int_frac(PIO pio, unsigned sm,
                                                uint32_t div_int, uint8_t div_frac) {
    pio->sm[sm].clkdiv = ((uint32_t)div_frac << PIO_SM0_CLKDIV_FRAC_LSB)
                        | (div_int << PIO_SM0_CLKDIV_INT_LSB);
}

static inline void pio_sm_set_clkdiv(PIO pio, unsigned sm, float div) {
    uint32_t div_int = (uint32_t)div;
    uint8_t div_frac = (uint8_t)((div - (float)div_int) * 256.0f);
    pio_sm_set_clkdiv_int_frac(pio, sm, div_int, div_frac);
}

// -----------------------------------------------------------------------
// Wrap
// -----------------------------------------------------------------------
static inline void pio_sm_set_wrap(PIO pio, unsigned sm, unsigned wrap_target, unsigned wrap) {
    pio->sm[sm].execctrl = (pio->sm[sm].execctrl &
                             ~(PIO_SM0_EXECCTRL_WRAP_TOP_BITS | PIO_SM0_EXECCTRL_WRAP_BOTTOM_BITS))
                          | (wrap_target << PIO_SM0_EXECCTRL_WRAP_BOTTOM_LSB)
                          | (wrap << PIO_SM0_EXECCTRL_WRAP_TOP_LSB);
}

// -----------------------------------------------------------------------
// FIFO access
// -----------------------------------------------------------------------
static inline void pio_sm_put(PIO pio, unsigned sm, uint32_t data) {
    pio->txf[sm] = data;
}

static inline uint32_t pio_sm_get(PIO pio, unsigned sm) {
    return pio->rxf[sm];
}

// -----------------------------------------------------------------------
// FIFO status
// -----------------------------------------------------------------------
static inline bool pio_sm_is_rx_fifo_full(PIO pio, unsigned sm) {
    return (pio->fstat & (1u << (PIO_FSTAT_RXFULL_LSB + sm))) != 0;
}

static inline bool pio_sm_is_rx_fifo_empty(PIO pio, unsigned sm) {
    return (pio->fstat & (1u << (PIO_FSTAT_RXEMPTY_LSB + sm))) != 0;
}

static inline bool pio_sm_is_tx_fifo_full(PIO pio, unsigned sm) {
    return (pio->fstat & (1u << (PIO_FSTAT_TXFULL_LSB + sm))) != 0;
}

static inline bool pio_sm_is_tx_fifo_empty(PIO pio, unsigned sm) {
    return (pio->fstat & (1u << (PIO_FSTAT_TXEMPTY_LSB + sm))) != 0;
}

// FIFO level (via FLEVEL register — returns 0 if unimplemented)
static inline unsigned pio_sm_get_rx_fifo_level(PIO pio, unsigned sm) {
    uint32_t bitoffs = sm * 8u + 4u;
    return (pio->flevel >> bitoffs) & 0xfu;
}

static inline unsigned pio_sm_get_tx_fifo_level(PIO pio, unsigned sm) {
    uint32_t bitoffs = sm * 8u;
    return (pio->flevel >> bitoffs) & 0xfu;
}

// -----------------------------------------------------------------------
// Blocking FIFO access
// -----------------------------------------------------------------------
static inline void pio_sm_put_blocking(PIO pio, unsigned sm, uint32_t data) {
    while (pio_sm_is_tx_fifo_full(pio, sm)) {
        tight_loop_contents();
    }
    pio_sm_put(pio, sm, data);
}

static inline uint32_t pio_sm_get_blocking(PIO pio, unsigned sm) {
    while (pio_sm_is_rx_fifo_empty(pio, sm)) {
        tight_loop_contents();
    }
    return pio_sm_get(pio, sm);
}

// -----------------------------------------------------------------------
// FIFO clear / drain
// -----------------------------------------------------------------------
static inline void pio_sm_clear_fifos(PIO pio, unsigned sm) {
    // Toggle FJOIN_RX twice — Pico SDK technique to flush both FIFOs
    hw_xor_bits(&pio->sm[sm].shiftctrl, PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS);
    hw_xor_bits(&pio->sm[sm].shiftctrl, PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS);
}

static inline void pio_sm_drain_tx_fifo(PIO pio, unsigned sm) {
    while (!pio_sm_is_tx_fifo_empty(pio, sm)) {
        (void)pio->rxf[sm];  // dummy read
        tight_loop_contents();
    }
}

// -----------------------------------------------------------------------
// Program loading
// -----------------------------------------------------------------------
static inline void pio_clear_instruction_memory(PIO pio) {
    for (unsigned i = 0; i < PIO_INSTRUCTION_COUNT; i++) {
        pio->instr_mem[i] = pio_encode_jmp(i);  // JMP to self (safe NOP)
    }
    _pio_used_instruction_space = 0;
}

static inline bool pio_can_add_program_at_offset(PIO pio, const pio_program_t *program,
                                                   unsigned offset) {
    (void)pio;
    uint32_t mask = ((1u << program->length) - 1u) << offset;
    return (offset + program->length <= PIO_INSTRUCTION_COUNT) &&
           (_pio_used_instruction_space & mask) == 0;
}

static inline bool pio_can_add_program(PIO pio, const pio_program_t *program) {
    if (program->origin >= 0) {
        return pio_can_add_program_at_offset(pio, program, (unsigned)program->origin);
    }
    for (unsigned i = 0; i + program->length <= PIO_INSTRUCTION_COUNT; i++) {
        if (pio_can_add_program_at_offset(pio, program, i)) {
            return true;
        }
    }
    return false;
}

static inline int pio_add_program_at_offset(PIO pio, const pio_program_t *program,
                                              unsigned offset) {
    if (!pio_can_add_program_at_offset(pio, program, offset)) {
        return PICO_ERROR_GENERIC;
    }
    for (unsigned i = 0; i < program->length; i++) {
        pio->instr_mem[offset + i] = program->instructions[i];
    }
    _pio_used_instruction_space |= ((1u << program->length) - 1u) << offset;
    return (int)offset;
}

static inline int pio_add_program(PIO pio, const pio_program_t *program) {
    if (program->origin >= 0) {
        return pio_add_program_at_offset(pio, program, (unsigned)program->origin);
    }
    for (unsigned i = 0; i + program->length <= PIO_INSTRUCTION_COUNT; i++) {
        if (pio_can_add_program_at_offset(pio, program, i)) {
            return pio_add_program_at_offset(pio, program, i);
        }
    }
    return PICO_ERROR_GENERIC;
}

static inline void pio_remove_program(PIO pio, const pio_program_t *program, unsigned offset) {
    (void)pio;
    _pio_used_instruction_space &= ~(((1u << program->length) - 1u) << offset);
}

// -----------------------------------------------------------------------
// SM claiming
// -----------------------------------------------------------------------
static inline void pio_sm_claim(PIO pio, unsigned sm) {
    (void)pio;
    _pio_sm_claimed |= (1u << sm);
}

static inline void pio_sm_unclaim(PIO pio, unsigned sm) {
    (void)pio;
    _pio_sm_claimed &= ~(1u << sm);
}

static inline bool pio_sm_is_claimed(PIO pio, unsigned sm) {
    (void)pio;
    return (_pio_sm_claimed & (1u << sm)) != 0;
}

static inline int pio_claim_unused_sm(PIO pio, bool required) {
    (void)pio;
    (void)required;
    for (unsigned i = 0; i < NUM_PIO_STATE_MACHINES; i++) {
        if (!(_pio_sm_claimed & (1u << i))) {
            _pio_sm_claimed |= (1u << i);
            return (int)i;
        }
    }
    return PICO_ERROR_GENERIC;
}

// -----------------------------------------------------------------------
// Pin helpers (via forced SET instructions)
// -----------------------------------------------------------------------
static inline void pio_sm_set_consecutive_pindirs(PIO pio, unsigned sm,
                                                    unsigned pin_base, unsigned pin_count,
                                                    bool is_out) {
    // Save and modify pinctrl to point SET at the target pins
    uint32_t pinctrl_saved = pio->sm[sm].pinctrl;
    unsigned remaining = pin_count;
    unsigned base = pin_base;
    while (remaining > 0) {
        unsigned count = remaining > 5 ? 5 : remaining;
        pio->sm[sm].pinctrl = (base << PIO_SM0_PINCTRL_SET_BASE_LSB)
                            | (count << PIO_SM0_PINCTRL_SET_COUNT_LSB);
        pio_sm_exec(pio, sm, pio_encode_set(pio_pindirs, is_out ? 0x1f : 0));
        remaining -= count;
        base = (base + count) & 0x1f;
    }
    pio->sm[sm].pinctrl = pinctrl_saved;
}

static inline void pio_sm_set_pins(PIO pio, unsigned sm, uint32_t pin_values) {
    uint32_t pinctrl_saved = pio->sm[sm].pinctrl;
    // Set 5 pins at a time (max for SET instruction)
    for (unsigned base = 0; base < 32; base += 5) {
        unsigned count = (32 - base) > 5 ? 5 : (32 - base);
        pio->sm[sm].pinctrl = (base << PIO_SM0_PINCTRL_SET_BASE_LSB)
                            | (count << PIO_SM0_PINCTRL_SET_COUNT_LSB);
        pio_sm_exec(pio, sm, pio_encode_set(pio_pins, (pin_values >> base) & 0x1f));
    }
    pio->sm[sm].pinctrl = pinctrl_saved;
}

static inline void pio_sm_set_pins_with_mask(PIO pio, unsigned sm,
                                               uint32_t pin_values, uint32_t pin_mask) {
    uint32_t pinctrl_saved = pio->sm[sm].pinctrl;
    while (pin_mask) {
        unsigned base = _pio_ctz(pin_mask);  // lowest set bit
        pio->sm[sm].pinctrl = (base << PIO_SM0_PINCTRL_SET_BASE_LSB)
                            | (1u << PIO_SM0_PINCTRL_SET_COUNT_LSB);
        pio_sm_exec(pio, sm, pio_encode_set(pio_pins, (pin_values >> base) & 1u));
        pin_mask &= ~(1u << base);
    }
    pio->sm[sm].pinctrl = pinctrl_saved;
}

static inline void pio_sm_set_pindirs_with_mask(PIO pio, unsigned sm,
                                                  uint32_t pin_dirs, uint32_t pin_mask) {
    uint32_t pinctrl_saved = pio->sm[sm].pinctrl;
    while (pin_mask) {
        unsigned base = _pio_ctz(pin_mask);
        pio->sm[sm].pinctrl = (base << PIO_SM0_PINCTRL_SET_BASE_LSB)
                            | (1u << PIO_SM0_PINCTRL_SET_COUNT_LSB);
        pio_sm_exec(pio, sm, pio_encode_set(pio_pindirs, (pin_dirs >> base) & 1u));
        pin_mask &= ~(1u << base);
    }
    pio->sm[sm].pinctrl = pinctrl_saved;
}

// -----------------------------------------------------------------------
// SM init (the big one — matches Pico SDK pio_sm_init sequence)
// -----------------------------------------------------------------------
static inline int pio_sm_init(PIO pio, unsigned sm, unsigned initial_pc,
                               const pio_sm_config *config) {
    // 1. Disable SM
    pio_sm_set_enabled(pio, sm, false);

    // 2. Apply config (or defaults)
    if (config) {
        pio_sm_set_config(pio, sm, config);
    } else {
        pio_sm_config c = pio_get_default_sm_config();
        pio_sm_set_config(pio, sm, &c);
    }

    // 3. Clear FIFOs
    pio_sm_clear_fifos(pio, sm);

    // 4. Clear FDEBUG sticky flags for this SM (writes to W1C register)
    pio->fdebug = ((1u << PIO_FDEBUG_TXOVER_LSB) |
                   (1u << PIO_FDEBUG_RXUNDER_LSB) |
                   (1u << PIO_FDEBUG_TXSTALL_LSB) |
                   (1u << PIO_FDEBUG_RXSTALL_LSB)) << sm;

    // 5. Restart SM and clock divider
    pio_sm_restart(pio, sm);
    pio_sm_clkdiv_restart(pio, sm);

    // 6. Jump to initial PC
    pio_sm_exec(pio, sm, pio_encode_jmp(initial_pc));

    return PICO_OK;
}

#endif // HARDWARE_PIO_H

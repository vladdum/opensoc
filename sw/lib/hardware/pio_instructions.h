// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// PIO instruction encoding — Pico SDK compatible
// Matches raspberrypi/pico-sdk hardware/pio_instructions.h API

#ifndef HARDWARE_PIO_INSTRUCTIONS_H
#define HARDWARE_PIO_INSTRUCTIONS_H

#include <stdint.h>

#ifndef _u
#define _u(x) ((unsigned)(x))
#endif

// -----------------------------------------------------------------------
// Instruction opcode bits (bits [15:13])
// -----------------------------------------------------------------------
enum pio_instr_bits {
    pio_instr_bits_jmp  = 0x0000,
    pio_instr_bits_wait = 0x2000,
    pio_instr_bits_in   = 0x4000,
    pio_instr_bits_out  = 0x6000,
    pio_instr_bits_push = 0x8000,
    pio_instr_bits_pull = 0x8080,
    pio_instr_bits_mov  = 0xa000,
    pio_instr_bits_irq  = 0xc000,
    pio_instr_bits_set  = 0xe000,
};

// -----------------------------------------------------------------------
// Source/destination encoding (3-bit fields)
// -----------------------------------------------------------------------
enum pio_src_dest {
    pio_pins     = 0u,
    pio_x        = 1u,
    pio_y        = 2u,
    pio_null     = 3u,
    pio_pindirs  = 4u,
    pio_exec_mov = 4u,   // MOV dest only
    pio_status   = 5u,   // MOV src only
    pio_pc       = 5u,   // OUT dest / MOV dest
    pio_isr      = 6u,
    pio_osr      = 7u,
    pio_exec_out = 7u,   // OUT dest only
};

// -----------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------
static inline unsigned _pio_encode_instr_and_args(enum pio_instr_bits instr_bits,
                                                   unsigned arg1, unsigned arg2) {
    return _u(instr_bits) | ((_u(arg1)) << 5u) | (_u(arg2) & 0x1fu);
}

static inline unsigned _pio_encode_instr_and_src_dest(enum pio_instr_bits instr_bits,
                                                       enum pio_src_dest dest,
                                                       unsigned arg2) {
    return _pio_encode_instr_and_args(instr_bits, _u(dest) & 7u, arg2);
}

// -----------------------------------------------------------------------
// JMP encoders (opcode 000, condition in bits [7:5], address in bits [4:0])
// -----------------------------------------------------------------------
static inline unsigned _pio_encode_jmp(unsigned cond, unsigned addr) {
    return _pio_encode_instr_and_args(pio_instr_bits_jmp, cond, addr);
}

static inline unsigned pio_encode_jmp(unsigned addr) {
    return _pio_encode_jmp(0, addr);
}

static inline unsigned pio_encode_jmp_not_x(unsigned addr) {
    return _pio_encode_jmp(1, addr);
}

static inline unsigned pio_encode_jmp_x_dec(unsigned addr) {
    return _pio_encode_jmp(2, addr);
}

static inline unsigned pio_encode_jmp_not_y(unsigned addr) {
    return _pio_encode_jmp(3, addr);
}

static inline unsigned pio_encode_jmp_y_dec(unsigned addr) {
    return _pio_encode_jmp(4, addr);
}

static inline unsigned pio_encode_jmp_x_ne_y(unsigned addr) {
    return _pio_encode_jmp(5, addr);
}

static inline unsigned pio_encode_jmp_pin(unsigned addr) {
    return _pio_encode_jmp(6, addr);
}

static inline unsigned pio_encode_jmp_not_osre(unsigned addr) {
    return _pio_encode_jmp(7, addr);
}

// -----------------------------------------------------------------------
// WAIT encoders (opcode 001)
// arg1[2]=polarity, arg1[1:0]=source, arg2=index
// -----------------------------------------------------------------------
static inline unsigned pio_encode_wait_gpio(unsigned polarity, unsigned gpio) {
    return _pio_encode_instr_and_args(pio_instr_bits_wait,
                                       (polarity ? 4u : 0u) | 0u, gpio);
}

static inline unsigned pio_encode_wait_pin(unsigned polarity, unsigned pin) {
    return _pio_encode_instr_and_args(pio_instr_bits_wait,
                                       (polarity ? 4u : 0u) | 1u, pin);
}

static inline unsigned pio_encode_wait_irq(unsigned polarity, unsigned relative,
                                            unsigned irq) {
    return _pio_encode_instr_and_args(pio_instr_bits_wait,
                                       (polarity ? 4u : 0u) | 2u,
                                       (relative ? 0x10u : 0u) | irq);
}

// -----------------------------------------------------------------------
// IN encoder (opcode 010, source in bits [7:5], bit_count in bits [4:0])
// bit_count of 32 is encoded as 0
// -----------------------------------------------------------------------
static inline unsigned pio_encode_in(enum pio_src_dest src, unsigned count) {
    return _pio_encode_instr_and_src_dest(pio_instr_bits_in, src, count & 0x1fu);
}

// -----------------------------------------------------------------------
// OUT encoder (opcode 011, destination in bits [7:5], bit_count in bits [4:0])
// bit_count of 32 is encoded as 0
// -----------------------------------------------------------------------
static inline unsigned pio_encode_out(enum pio_src_dest dest, unsigned count) {
    return _pio_encode_instr_and_src_dest(pio_instr_bits_out, dest, count & 0x1fu);
}

// -----------------------------------------------------------------------
// PUSH encoder (opcode 100, bit7=0)
// -----------------------------------------------------------------------
static inline unsigned pio_encode_push(unsigned if_full, unsigned block) {
    return _pio_encode_instr_and_args(pio_instr_bits_push,
                                       (if_full ? 2u : 0u) | (block ? 1u : 0u), 0);
}

// -----------------------------------------------------------------------
// PULL encoder (opcode 100, bit7=1)
// -----------------------------------------------------------------------
static inline unsigned pio_encode_pull(unsigned if_empty, unsigned block) {
    return _pio_encode_instr_and_args(pio_instr_bits_pull,
                                       (if_empty ? 2u : 0u) | (block ? 1u : 0u), 0);
}

// -----------------------------------------------------------------------
// MOV encoders (opcode 101)
// dest in bits [7:5], operation in bits [4:3], source in bits [2:0]
// -----------------------------------------------------------------------
static inline unsigned pio_encode_mov(enum pio_src_dest dest, enum pio_src_dest src) {
    return _pio_encode_instr_and_src_dest(pio_instr_bits_mov, dest, _u(src) & 7u);
}

static inline unsigned pio_encode_mov_not(enum pio_src_dest dest, enum pio_src_dest src) {
    return _pio_encode_instr_and_src_dest(pio_instr_bits_mov, dest,
                                           (1u << 3u) | (_u(src) & 7u));
}

static inline unsigned pio_encode_mov_reverse(enum pio_src_dest dest, enum pio_src_dest src) {
    return _pio_encode_instr_and_src_dest(pio_instr_bits_mov, dest,
                                           (2u << 3u) | (_u(src) & 7u));
}

// -----------------------------------------------------------------------
// IRQ encoders (opcode 110)
// -----------------------------------------------------------------------
static inline unsigned _pio_encode_irq(unsigned relative, unsigned irq) {
    return (relative ? 0x10u : 0u) | irq;
}

static inline unsigned pio_encode_irq_set(unsigned relative, unsigned irq) {
    return _pio_encode_instr_and_args(pio_instr_bits_irq, 0, _pio_encode_irq(relative, irq));
}

static inline unsigned pio_encode_irq_wait(unsigned relative, unsigned irq) {
    return _pio_encode_instr_and_args(pio_instr_bits_irq, 2, _pio_encode_irq(relative, irq));
}

static inline unsigned pio_encode_irq_clear(unsigned relative, unsigned irq) {
    return _pio_encode_instr_and_args(pio_instr_bits_irq, 1, _pio_encode_irq(relative, irq));
}

// -----------------------------------------------------------------------
// SET encoder (opcode 111, destination in bits [7:5], value in bits [4:0])
// -----------------------------------------------------------------------
static inline unsigned pio_encode_set(enum pio_src_dest dest, unsigned value) {
    return _pio_encode_instr_and_src_dest(pio_instr_bits_set, dest, value);
}

// -----------------------------------------------------------------------
// NOP (MOV Y, Y)
// -----------------------------------------------------------------------
static inline unsigned pio_encode_nop(void) {
    return pio_encode_mov(pio_y, pio_y);
}

// -----------------------------------------------------------------------
// Delay and side-set (OR into bits [12:8])
// -----------------------------------------------------------------------
static inline unsigned pio_encode_delay(unsigned cycles) {
    return cycles << 8u;
}

static inline unsigned pio_encode_sideset(unsigned sideset_bit_count, unsigned value) {
    return value << (13u - sideset_bit_count);
}

static inline unsigned pio_encode_sideset_opt(unsigned sideset_bit_count, unsigned value) {
    return 0x1000u | (value << (12u - sideset_bit_count));
}

#endif // HARDWARE_PIO_INSTRUCTIONS_H

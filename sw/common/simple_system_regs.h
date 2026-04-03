// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// OpenSoC override of ibex simple_system_regs.h.
// Updated for ARM Cortex-M style memory map (peripherals at 0x40000000+).
// This file shadows the ibex version when sw/common/ is first on the
// include path — see each test's Makefile for how this is arranged.

#ifndef SIMPLE_SYSTEM_REGS_H__
#define SIMPLE_SYSTEM_REGS_H__

#define SIM_CTRL_BASE  0x40000000UL
#define SIM_CTRL_OUT   0x0
#define SIM_CTRL_CTRL  0x8

#define TIMER_BASE      0x40010000UL
#define TIMER_MTIME     0x0
#define TIMER_MTIMEH    0x4
#define TIMER_MTIMECMP  0x8
#define TIMER_MTIMECMPH 0xC

#endif  // SIMPLE_SYSTEM_REGS_H__

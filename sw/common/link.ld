/* Copyright OpenSoC contributors.
   Licensed under the Apache License, Version 2.0, see LICENSE for details.
   SPDX-License-Identifier: Apache-2.0 */

OUTPUT_ARCH(riscv)

MEMORY
{
    ram   : ORIGIN = 0x20000000, LENGTH = 0x78000  /* 480 KB code + data */
    stack : ORIGIN = 0x20078000, LENGTH = 0x8000   /* 32 KB stack — top of 512 KB FPGA RAM */
}

_min_stack   = 0x2000;
_stack_len   = LENGTH(stack);
_stack_start = ORIGIN(stack) + LENGTH(stack);  /* = 0x20080000 */

_entry_point = _vectors_start + 0x80;
ENTRY(_entry_point)

/* tohost = SIM_CTRL_BASE + SIM_CTRL_CTRL (0x40000000 + 0x8).
   Spike reads this address to detect simulation exit; Verilator's
   VerilatorSimCtrl watches for a write here in the same way. */
tohost   = 0x40000008;
fromhost = _stack_start + 0x10;

SECTIONS
{
    .vectors :
    {
        . = ALIGN(4);
        _vectors_start = .;
        KEEP(*(.vectors))
        _vectors_end = .;
    } > ram

    .text : {
        . = ALIGN(4);
        *(.text)
        *(.text.*)
    } > ram

    .rodata : {
        . = ALIGN(4);
        *(.srodata)
        *(.srodata.*)
        *(.rodata)
        *(.rodata.*)
    } > ram

    .data : {
        . = ALIGN(8);
        *(.sdata)
        *(.sdata.*)
        *(.data)
        *(.data.*)
    } > ram

    .bss : {
        . = ALIGN(8);
        _bss_start = .;
        *(.sbss)
        *(.sbss.*)
        *(.bss)
        *(.bss.*)
        *(COMMON)
        _bss_end = .;
    } > ram

    .stack (NOLOAD): {
        . = ALIGN(16);
        . = . + _min_stack;
        . = ALIGN(16);
        stack = .;
        _stack = .;
    } > stack
}

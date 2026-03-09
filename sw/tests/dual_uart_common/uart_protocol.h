// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Shared protocol header for dual-UART bidirectional communication test.
//
// Packet format on the wire:
//   SYNC (0xA5) | SEQ (u8) | LEN (u8) | PAYLOAD (LEN bytes) | CHECKSUM
//
// CHECKSUM = XOR of SYNC, SEQ, LEN, and all payload bytes.
// First payload byte encodes the packet type.

#ifndef UART_PROTOCOL_H_
#define UART_PROTOCOL_H_

#include "simple_system_common.h"

// ---------------------------------------------------------------------------
// UART hardware registers (same base for both SoCs)
// ---------------------------------------------------------------------------
#define UART_BASE          0x40000
#define UART_THR           0x00   // TX hold / RX buffer
#define UART_LSR           0x04   // Line status
#define UART_DIV           0x0C   // Baud divisor

#define UART_LSR_TX_READY  (1 << 0)  // TX FIFO not full
#define UART_LSR_RX_READY  (1 << 1)  // RX FIFO not empty

// ---------------------------------------------------------------------------
// Protocol constants
// ---------------------------------------------------------------------------
#define PKT_SYNC          0xA5
#define PKT_MAX_PAYLOAD   32

#define PKT_TYPE_SYNC_REQ 0x01
#define PKT_TYPE_SYNC_ACK 0x02
#define PKT_TYPE_DATA     0x03
#define PKT_TYPE_DONE     0x04

#define NUM_DATA_ROUNDS   8
#define DATA_PAYLOAD_LEN  16   // bytes per DATA packet payload (including type byte)

// ---------------------------------------------------------------------------
// Packet structure
// ---------------------------------------------------------------------------
typedef struct {
  uint8_t seq;
  uint8_t len;                       // payload length
  uint8_t payload[PKT_MAX_PAYLOAD];
  uint8_t checksum;
  int     valid;                     // set by uart_recv_pkt
} uart_pkt_t;

// ---------------------------------------------------------------------------
// Low-level UART I/O (polling)
// ---------------------------------------------------------------------------
static inline void uart_init(uint32_t divisor) {
  DEV_WRITE(UART_BASE + UART_DIV, divisor);
}

static inline void uart_putc(uint8_t c) {
  while (!(DEV_READ(UART_BASE + UART_LSR, 0) & UART_LSR_TX_READY))
    ;
  DEV_WRITE(UART_BASE + UART_THR, (uint32_t)c);
}

static inline uint8_t uart_getc(void) {
  while (!(DEV_READ(UART_BASE + UART_LSR, 0) & UART_LSR_RX_READY))
    ;
  return (uint8_t)(DEV_READ(UART_BASE + UART_THR, 0) & 0xFF);
}

// ---------------------------------------------------------------------------
// Checksum
// ---------------------------------------------------------------------------
static inline uint8_t compute_checksum(uint8_t seq, uint8_t len,
                                       const uint8_t *payload) {
  uint8_t cksum = PKT_SYNC ^ seq ^ len;
  for (uint8_t i = 0; i < len; i++) {
    cksum ^= payload[i];
  }
  return cksum;
}

// ---------------------------------------------------------------------------
// Send a packet
// ---------------------------------------------------------------------------
static inline void uart_send_pkt(const uart_pkt_t *pkt) {
  uart_putc(PKT_SYNC);
  uart_putc(pkt->seq);
  uart_putc(pkt->len);
  for (uint8_t i = 0; i < pkt->len; i++) {
    uart_putc(pkt->payload[i]);
  }
  uint8_t cksum = compute_checksum(pkt->seq, pkt->len, pkt->payload);
  uart_putc(cksum);
}

// ---------------------------------------------------------------------------
// Receive a packet (blocks until SYNC byte found)
// ---------------------------------------------------------------------------
static inline void uart_recv_pkt(uart_pkt_t *pkt) {
  // Wait for sync byte
  uint8_t b;
  do {
    b = uart_getc();
  } while (b != PKT_SYNC);

  pkt->seq = uart_getc();
  pkt->len = uart_getc();

  // Clamp to max payload to prevent buffer overflow
  uint8_t rlen = pkt->len;
  if (rlen > PKT_MAX_PAYLOAD) rlen = PKT_MAX_PAYLOAD;

  for (uint8_t i = 0; i < rlen; i++) {
    pkt->payload[i] = uart_getc();
  }
  // Consume any extra bytes if len was clamped
  for (uint8_t i = rlen; i < pkt->len; i++) {
    (void)uart_getc();
  }
  pkt->len = rlen;

  pkt->checksum = uart_getc();

  uint8_t expected = compute_checksum(pkt->seq, pkt->len, pkt->payload);
  pkt->valid = (pkt->checksum == expected);
}

// ---------------------------------------------------------------------------
// Data pattern generation and verification
// ---------------------------------------------------------------------------

// Fill payload[1..DATA_PAYLOAD_LEN-1] with deterministic pattern.
// payload[0] is the packet type (set by caller).
static inline void fill_data_pattern(uint8_t *payload, uint8_t seed,
                                     uint8_t round) {
  for (int i = 1; i < DATA_PAYLOAD_LEN; i++) {
    payload[i] = (uint8_t)(seed + round * 17 + i * 3);
  }
}

// Verify payload[1..DATA_PAYLOAD_LEN-1] matches expected pattern.
// Returns 1 on match, 0 on mismatch.
static inline int verify_data_pattern(const uint8_t *payload, uint8_t seed,
                                      uint8_t round) {
  for (int i = 1; i < DATA_PAYLOAD_LEN; i++) {
    uint8_t expected = (uint8_t)(seed + round * 17 + i * 3);
    if (payload[i] != expected) {
      return 0;
    }
  }
  return 1;
}

// ---------------------------------------------------------------------------
// Diagnostic output via SimCtrl (puts/puthex)
// ---------------------------------------------------------------------------
static inline void print_dec(int val) {
  if (val < 0) {
    putchar('-');
    val = -val;
  }
  if (val >= 10) {
    print_dec(val / 10);
  }
  putchar('0' + (val % 10));
}

static inline void print_pkt_info(const char *prefix, const uart_pkt_t *pkt) {
  puts(prefix);
  puts(" seq=");
  print_dec(pkt->seq);
  puts(" len=");
  print_dec(pkt->len);
  puts(" type=0x");
  puthex(pkt->payload[0]);
  puts(" valid=");
  putchar(pkt->valid ? '1' : '0');
  putchar('\n');
}

#endif  // UART_PROTOCOL_H_

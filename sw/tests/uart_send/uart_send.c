// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// SoC0 (initiator): bidirectional framed-protocol UART test.
//
// Phase 1 — Handshake: send SYNC_REQ("PING"), expect SYNC_ACK("PONG").
// Phase 2 — Data exchange: 8 lockstep rounds, SoC0 sends then receives.
// Phase 3 — Completion: exchange DONE packets, report PASS/FAIL, spin on WFI.

#include "../dual_uart_common/uart_protocol.h"

#define MY_SEED       37
#define PEER_SEED     53

int main(int argc, char **argv) {
  uart_pkt_t tx_pkt, rx_pkt;
  int errors = 0;
  uint8_t seq = 0;

  puts("SoC0: protocol test starting\n");
  uart_init(16);

  // ----- Phase 1: Handshake -----
  // Send SYNC_REQ with "PING" payload
  tx_pkt.seq = seq++;
  tx_pkt.len = 5;
  tx_pkt.payload[0] = PKT_TYPE_SYNC_REQ;
  tx_pkt.payload[1] = 'P';
  tx_pkt.payload[2] = 'I';
  tx_pkt.payload[3] = 'N';
  tx_pkt.payload[4] = 'G';
  uart_send_pkt(&tx_pkt);
  puts("SoC0: sent SYNC_REQ\n");

  // Wait for SYNC_ACK
  uart_recv_pkt(&rx_pkt);
  print_pkt_info("SoC0: RX", &rx_pkt);

  if (!rx_pkt.valid || rx_pkt.payload[0] != PKT_TYPE_SYNC_ACK) {
    puts("SoC0: ERROR handshake failed\n");
    errors++;
  } else {
    // Verify "PONG"
    if (rx_pkt.len != 5 ||
        rx_pkt.payload[1] != 'P' || rx_pkt.payload[2] != 'O' ||
        rx_pkt.payload[3] != 'N' || rx_pkt.payload[4] != 'G') {
      puts("SoC0: ERROR bad SYNC_ACK payload\n");
      errors++;
    } else {
      puts("SoC0: handshake OK\n");
    }
  }

  // ----- Phase 2: Data exchange (8 rounds) -----
  for (int round = 0; round < NUM_DATA_ROUNDS; round++) {
    // Send DATA packet
    tx_pkt.seq = seq++;
    tx_pkt.len = DATA_PAYLOAD_LEN;
    tx_pkt.payload[0] = PKT_TYPE_DATA;
    fill_data_pattern(tx_pkt.payload, MY_SEED, (uint8_t)round);
    uart_send_pkt(&tx_pkt);

    // Receive DATA packet from peer
    uart_recv_pkt(&rx_pkt);

    int data_ok = rx_pkt.valid &&
                  rx_pkt.payload[0] == PKT_TYPE_DATA &&
                  verify_data_pattern(rx_pkt.payload, PEER_SEED, (uint8_t)round);

    puts("SoC0: RX seq=");
    print_dec(rx_pkt.seq);
    puts(" valid=");
    putchar(data_ok ? '1' : '0');
    putchar('\n');

    if (!data_ok) {
      puts("SoC0: ERROR data mismatch round ");
      print_dec(round);
      putchar('\n');
      errors++;
    }
  }

  // ----- Phase 3: Completion -----
  // Send DONE
  tx_pkt.seq = seq++;
  tx_pkt.len = 1;
  tx_pkt.payload[0] = PKT_TYPE_DONE;
  uart_send_pkt(&tx_pkt);

  // Receive DONE from peer
  uart_recv_pkt(&rx_pkt);
  if (!rx_pkt.valid || rx_pkt.payload[0] != PKT_TYPE_DONE) {
    puts("SoC0: ERROR missing DONE from peer\n");
    errors++;
  }

  // Report result
  if (errors == 0) {
    puts("SoC0: PASS\n");
  } else {
    puts("SoC0: FAIL (errors=");
    print_dec(errors);
    puts(")\n");
  }

  // Spin — let SoC1 halt the simulation
  while (1) {
    asm volatile("wfi");
  }
}

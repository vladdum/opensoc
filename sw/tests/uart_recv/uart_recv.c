// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// SoC1 (responder): bidirectional framed-protocol UART test.
//
// Phase 1 — Handshake: expect SYNC_REQ("PING"), reply SYNC_ACK("PONG").
// Phase 2 — Data exchange: 8 lockstep rounds, SoC1 receives then sends.
// Phase 3 — Completion: exchange DONE packets, report PASS/FAIL, return (halts sim).

#include "../dual_uart_common/uart_protocol.h"

#define MY_SEED       53
#define PEER_SEED     37

int main(int argc, char **argv) {
  uart_pkt_t tx_pkt, rx_pkt;
  int errors = 0;
  uint8_t seq = 0;

  puts("SoC1: protocol test starting\n");
  uart_init(16);

  // ----- Phase 1: Handshake -----
  // Wait for SYNC_REQ
  uart_recv_pkt(&rx_pkt);
  print_pkt_info("SoC1: RX", &rx_pkt);

  if (!rx_pkt.valid || rx_pkt.payload[0] != PKT_TYPE_SYNC_REQ) {
    puts("SoC1: ERROR bad SYNC_REQ\n");
    errors++;
  } else {
    // Verify "PING"
    if (rx_pkt.len != 5 ||
        rx_pkt.payload[1] != 'P' || rx_pkt.payload[2] != 'I' ||
        rx_pkt.payload[3] != 'N' || rx_pkt.payload[4] != 'G') {
      puts("SoC1: ERROR bad SYNC_REQ payload\n");
      errors++;
    } else {
      puts("SoC1: handshake SYNC_REQ OK\n");
    }
  }

  // Reply SYNC_ACK with "PONG"
  tx_pkt.seq = seq++;
  tx_pkt.len = 5;
  tx_pkt.payload[0] = PKT_TYPE_SYNC_ACK;
  tx_pkt.payload[1] = 'P';
  tx_pkt.payload[2] = 'O';
  tx_pkt.payload[3] = 'N';
  tx_pkt.payload[4] = 'G';
  uart_send_pkt(&tx_pkt);
  puts("SoC1: sent SYNC_ACK\n");

  // ----- Phase 2: Data exchange (8 rounds) -----
  for (int round = 0; round < NUM_DATA_ROUNDS; round++) {
    // Receive DATA packet from peer
    uart_recv_pkt(&rx_pkt);

    int data_ok = rx_pkt.valid &&
                  rx_pkt.payload[0] == PKT_TYPE_DATA &&
                  verify_data_pattern(rx_pkt.payload, PEER_SEED, (uint8_t)round);

    puts("SoC1: RX seq=");
    print_dec(rx_pkt.seq);
    puts(" valid=");
    putchar(data_ok ? '1' : '0');
    putchar('\n');

    if (!data_ok) {
      puts("SoC1: ERROR data mismatch round ");
      print_dec(round);
      putchar('\n');
      errors++;
    }

    // Send DATA packet back
    tx_pkt.seq = seq++;
    tx_pkt.len = DATA_PAYLOAD_LEN;
    tx_pkt.payload[0] = PKT_TYPE_DATA;
    fill_data_pattern(tx_pkt.payload, MY_SEED, (uint8_t)round);
    uart_send_pkt(&tx_pkt);
  }

  // ----- Phase 3: Completion -----
  // Receive DONE from peer
  uart_recv_pkt(&rx_pkt);
  if (!rx_pkt.valid || rx_pkt.payload[0] != PKT_TYPE_DONE) {
    puts("SoC1: ERROR missing DONE from peer\n");
    errors++;
  }

  // Send DONE
  tx_pkt.seq = seq++;
  tx_pkt.len = 1;
  tx_pkt.payload[0] = PKT_TYPE_DONE;
  uart_send_pkt(&tx_pkt);

  // Report result
  if (errors == 0) {
    puts("SoC1: PASS\n");
  } else {
    puts("SoC1: FAIL (errors=");
    print_dec(errors);
    puts(")\n");
  }

  // Return from main — crt0 calls sim_halt()
  return 0;
}

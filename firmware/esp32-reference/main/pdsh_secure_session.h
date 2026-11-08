// SPDX-License-Identifier: MIT
/* secure-session-v1 board session: TLS 1.3 server profile (§6), readiness and
 * request processing (§8, §9) over an abstract byte stream.
 *
 * Transport-agnostic and host-buildable: a transport (the BLE LE CoC on the
 * device, a memory pipe in host tests, or a simulated transport in a
 * cross-runtime test) pushes received bytes with pdsh_ss_conn_rx(), calls
 * pdsh_ss_conn_poll() and drains pdsh_ss_conn_tx(). The LE CoC/GATT binding
 * (§5) is pending secure-session-v2 (review item H3) and is not in this file. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "pdsh_enroll.h"
#include "pdsh_secure_msg.h"

/* Timer values are parameters (review item M3 may change them). */
typedef struct {
    uint32_t handshake_ms; /* CoC open -> local handshake complete */
    uint32_t ready_ms;     /* handshake complete -> ready_req */
    uint32_t idle_ms;      /* ready without a request */
    uint32_t lifetime_ms;  /* from handshake completion */
} pdsh_ss_timers_t;
extern const pdsh_ss_timers_t pdsh_ss_timers_v1;

typedef void (*pdsh_ss_emit_fn)(void *ctx, const uint8_t *frame, size_t n);
typedef void (*pdsh_ss_random_fn)(uint8_t *out, size_t n);

/* ---- application layer (plaintext inside TLS) ---- */
typedef enum { PDSH_SS_APP_VERIFIED, PDSH_SS_APP_READY, PDSH_SS_APP_CLOSED } pdsh_ss_app_state_t;
typedef struct {
    pdsh_ss_app_state_t state;
    pdsh_enroll_durable_t record; /* captured at handshake completion */
    char device_id[70], phone_id[72];
    char sc[PDSH_SS_CHALLENGE_HEX + 1];
    uint32_t last_seq;
    uint64_t started_ms, last_ms;
    const pdsh_ss_timers_t *timers;
    pdsh_ss_random_fn random;
    pdsh_frame_decoder_t frames;
    pdsh_ss_error_t close_code;
    pdsh_ss_emit_fn emit;
    void *emit_ctx;
} pdsh_ss_app_t;
/* Captures the committed record at handshake completion. Fails when the board
 * has no session authority or the verified peer pin is not the record phone. */
bool pdsh_ss_app_start(pdsh_ss_app_t *app, const char *verified_phone_fp, uint64_t now_ms,
                       const pdsh_ss_timers_t *timers, pdsh_ss_random_fn random, pdsh_ss_emit_fn emit,
                       void *emit_ctx);
/* Feeds decrypted stream bytes; returns false once the session is closed. */
bool pdsh_ss_app_input(pdsh_ss_app_t *app, const uint8_t *data, size_t n, uint64_t now_ms);
/* Timers and revocation; returns false once the session is closed. */
bool pdsh_ss_app_tick(pdsh_ss_app_t *app, uint64_t now_ms);
/* Peer EOF/close_notify: discards a partial frame (truncated). */
void pdsh_ss_app_close(pdsh_ss_app_t *app);

/* ---- TLS server connection over a byte stream ---- */
typedef struct pdsh_ss_conn pdsh_ss_conn_t;
typedef struct {
    const uint8_t *cert_der; /* device certificate (pdsh_cert_build) */
    size_t cert_len;
    uint32_t key_id;         /* PSA device key */
    const pdsh_ss_timers_t *timers;
    pdsh_ss_random_fn random;
} pdsh_ss_server_cfg_t;
typedef enum {
    PDSH_SS_CONN_HANDSHAKE,
    PDSH_SS_CONN_OPEN,
    PDSH_SS_CONN_CLOSED,
} pdsh_ss_conn_state_t;
pdsh_ss_conn_t *pdsh_ss_conn_new(const pdsh_ss_server_cfg_t *cfg, uint64_t now_ms);
void pdsh_ss_conn_free(pdsh_ss_conn_t *conn);
/* Queues transport bytes; false means the receive buffer would overflow
 * (a peer beyond its flow-control allowance): the transport must drop. */
bool pdsh_ss_conn_rx(pdsh_ss_conn_t *conn, const uint8_t *data, size_t n);
size_t pdsh_ss_conn_rx_free(const pdsh_ss_conn_t *conn);
/* Transport EOF (CoC loss). */
void pdsh_ss_conn_eof(pdsh_ss_conn_t *conn);
pdsh_ss_conn_state_t pdsh_ss_conn_poll(pdsh_ss_conn_t *conn, uint64_t now_ms);
/* Moves up to cap pending outbound transport bytes into out. */
size_t pdsh_ss_conn_tx(pdsh_ss_conn_t *conn, uint8_t *out, size_t cap);
/* Diagnostics: last certificate decision, TLS alert sent, close reason. */
const char *pdsh_ss_conn_reason(const pdsh_ss_conn_t *conn);
int pdsh_ss_conn_alert(const pdsh_ss_conn_t *conn);

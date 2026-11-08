// SPDX-License-Identifier: MIT
/* secure-session-v1 board session: TLS 1.3 server profile (§6), readiness and
 * request processing (§8, §9) over an abstract byte stream.
 *
 * Transport-agnostic and host-buildable: a transport (the BLE LE CoC on the
 * device, a memory pipe in host tests, or a simulated transport in a
 * cross-runtime test) pushes received bytes with pdsh_ss_conn_rx(), calls
 * pdsh_ss_conn_poll() and drains pdsh_ss_conn_tx(). The §5 LE CoC receive
 * path (credit accounting) is pdsh_ss_coc_* below; the NimBLE binding lives in
 * main.c. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "pdsh_enroll.h"
#include "pdsh_secure_msg.h"

/* Timer values (§5, §8.1). */
typedef struct {
    uint32_t handshake_ms; /* CoC open -> local handshake complete */
    uint32_t ready_ms;     /* handshake complete -> ready_req */
    uint32_t idle_ms;      /* ready without a request */
    uint32_t lifetime_ms;  /* from handshake completion */
} pdsh_ss_timers_t;
/* secure-session-v2 §8.1: 15 s, 10 s, idle 90 s, lifetime 600 s. */
extern const pdsh_ss_timers_t pdsh_ss_timers_v2;

typedef void (*pdsh_ss_emit_fn)(void *ctx, const uint8_t *frame, size_t n);
/* CSPRNG draw; false when no entropy source is active (§2). */
typedef bool (*pdsh_ss_random_fn)(uint8_t *out, size_t n);

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
/* Timers and the RAM revocation flag; returns false once closed. Lifetime
 * expiry closes with close_notify only (no err). */
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

/* ---- §5 pre-authentication LE CoC receive path ---- */
#define PDSH_SS_COC_MAX_KFRAMES 4
typedef enum {
    PDSH_COC_OK = 0,
    PDSH_COC_CREDIT_OVERRUN,
    PDSH_COC_KFRAME_OVERSIZE,
    PDSH_COC_SDU_OVERSIZE,
    PDSH_COC_SDU_EMPTY,
    PDSH_COC_SDU_OVERRUN,
    PDSH_COC_KFRAME_SHORT,
} pdsh_coc_close_t;
const char *pdsh_coc_close_name(pdsh_coc_close_t reason);
typedef struct {
    uint16_t mtu, mps;
    uint8_t buffers;      /* receive K-frame buffers; also the initial grant */
    uint8_t peer_credits; /* credits the peer still holds */
    uint8_t held;         /* K-frames buffered and not yet consumed */
    pdsh_coc_close_t closed;
    /* SDUs in arrival order: lengths and K-frame counts; data in one buffer
     * of buffers x mps bytes, used as a ring. */
    struct {
        uint16_t len, kframes;
    } sdu[PDSH_SS_COC_MAX_KFRAMES];
    uint8_t sdu_count;    /* complete SDUs queued */
    bool partial;
    uint16_t partial_len, partial_got, partial_kframes;
    uint8_t data[PDSH_SS_COC_MAX_KFRAMES * 512];
    size_t head, used;
} pdsh_ss_coc_t;
/* Returns false for an unsupported configuration (buffers 1..4, mps <= 512,
 * mtu >= 256). Initial credits = buffers. */
bool pdsh_ss_coc_init(pdsh_ss_coc_t *coc, uint16_t mtu, uint16_t mps, uint8_t buffers);
/* One received K-frame information payload. Credits are checked before any
 * receive slot is touched; a violation returns the close reason (sticky). */
pdsh_coc_close_t pdsh_ss_coc_kframe(pdsh_ss_coc_t *coc, const uint8_t *frame, size_t len);
/* Length of the oldest complete SDU (0 if none). */
size_t pdsh_ss_coc_ready(const pdsh_ss_coc_t *coc);
/* Consumes the oldest complete SDU into out (cap >= its length); returns its
 * length and the credits to return to the peer. */
size_t pdsh_ss_coc_consume(pdsh_ss_coc_t *coc, uint8_t *out, size_t cap, uint8_t *credits);

/* ---- §5 CoC admission: one session globally, 2 s back-off after a failed
 * or timed-out handshake, at most 3 consecutive failed handshakes per LE
 * connection. ---- */
typedef struct {
    bool open;
    uint16_t conn_handle;
    uint8_t failures;
    uint64_t backoff_until_ms;
} pdsh_ss_admission_t;
bool pdsh_ss_admit(pdsh_ss_admission_t *adm, uint16_t conn_handle, uint64_t now_ms);
/* reached_open: the TLS handshake completed (resets the failure count). */
void pdsh_ss_released(pdsh_ss_admission_t *adm, bool reached_open, uint64_t now_ms);

/* ---- §5 send path ownership (one NimBLE ble_l2cap_send return each) ---- */
typedef enum {
    PDSH_TX_RC_OK,         /* SDU fully handed over and freed by the stack */
    PDSH_TX_RC_STALLED,    /* BLE_HS_ESTALLED: the stack owns the SDU until TX_UNSTALLED */
    PDSH_TX_RC_NOT_TAKEN,  /* BLE_HS_EBUSY/EBADDATA/ENOTCONN before queueing: caller owns */
    PDSH_TX_RC_FAILED,     /* any other error: the stack freed it, bytes may be partial */
} pdsh_tx_rc_t;
typedef struct {
    uint8_t in_stack;      /* SDUs owned by the host stack (<= 2) */
    bool stalled, broken;
} pdsh_ss_tx_t;
bool pdsh_ss_tx_can_send(const pdsh_ss_tx_t *tx);
/* Records a send result; *caller_frees says who frees the mbuf. A failed or
 * not-taken send is never retried with the same bytes (no duplicate). */
void pdsh_ss_tx_sent(pdsh_ss_tx_t *tx, pdsh_tx_rc_t rc, bool *caller_frees);
void pdsh_ss_tx_unstalled(pdsh_ss_tx_t *tx, int status);
/* Channel gone: NimBLE frees a queued SDU in its channel cleanup. */
void pdsh_ss_tx_disconnected(pdsh_ss_tx_t *tx);

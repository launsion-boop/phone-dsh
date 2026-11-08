// SPDX-License-Identifier: MIT
/* secure-session-v1 identifiers, framing and message codec
 * (spec/device/v1/ble-secure-session.md §2, §7). Host-buildable: depends only
 * on cJSON, PSA crypto and the shared task validator. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "cJSON.h"

#define PDSH_SS_ALPN "pdsh-ble-task/1"
#define PDSH_SS_FRAME_MAX 4096
#define PDSH_SS_FP_HEX 64
#define PDSH_SS_EID_HEX 32
#define PDSH_SS_CHALLENGE_HEX 64

/* ---- identifiers (§2) ---- */
typedef enum {
    PDSH_KEY_OK = 0,
    PDSH_KEY_NOT_HEX,
    PDSH_KEY_UPPERCASE,
    PDSH_KEY_LENGTH,
    PDSH_KEY_NOT_UNCOMPRESSED,
    PDSH_KEY_COORDINATE_RANGE,
    PDSH_KEY_NOT_ON_CURVE,
    PDSH_KEY_INTERNAL,
} pdsh_key_status_t;
const char *pdsh_key_status_name(pdsh_key_status_t status);
/* Validates a hex public key text in the §2 order; on success fills point. */
pdsh_key_status_t pdsh_pubkey_check_hex(const char *hex, uint8_t point[65]);
/* Validates raw bytes in the §2 order (length, prefix, range, curve). */
pdsh_key_status_t pdsh_pubkey_check(const uint8_t *point, size_t len);
/* SHA-256 of exactly the 65 point bytes, lowercase hex. */
bool pdsh_fingerprint(const uint8_t point[65], char fp_hex[PDSH_SS_FP_HEX + 1]);
bool pdsh_lower_hex(const char *text, size_t length);
bool pdsh_device_id_valid(const char *text);
bool pdsh_phone_id_valid(const char *text);
void pdsh_hex_encode(const uint8_t *in, size_t n, char *out);
bool pdsh_hex_decode(const char *text, uint8_t *out, size_t n);

/* ---- framing (§7.1) ---- */
typedef struct {
    uint8_t buf[2 + PDSH_SS_FRAME_MAX];
    size_t have;
    bool failed;
} pdsh_frame_decoder_t;
typedef enum { PDSH_FRAME_MORE = 0, PDSH_FRAME_PAYLOAD = 1, PDSH_FRAME_LIMIT = -1 } pdsh_frame_result_t;
void pdsh_frame_reset(pdsh_frame_decoder_t *dec);
/* Consumes bytes from (*data, *n) until one payload is complete (PAYLOAD; the
 * payload points into the decoder and is valid until the next call), all
 * input is consumed (MORE) or the length is invalid (LIMIT, sticky). */
pdsh_frame_result_t pdsh_frame_next(pdsh_frame_decoder_t *dec, const uint8_t **data, size_t *n,
                                    const uint8_t **payload, size_t *payload_len);
/* True when bytes of an incomplete frame are pending (truncated at close). */
bool pdsh_frame_pending(const pdsh_frame_decoder_t *dec);
/* Writes length prefix and payload; out must hold n + 2 bytes; n in 1..4096. */
bool pdsh_frame_encode(const uint8_t *payload, size_t n, uint8_t *out);

/* ---- messages (§7.2-§7.4) ---- */
typedef enum {
    PDSH_MSG_READY_REQ,
    PDSH_MSG_NEXT,
    PDSH_MSG_ACCEPT,
    PDSH_MSG_COMPLETE,
    PDSH_MSG_FAIL,
    PDSH_MSG_STATUS,
    PDSH_MSG_ERR,
    PDSH_MSG_READY_ACK,
    PDSH_MSG_NEXT_R,
    PDSH_MSG_R,
    PDSH_MSG_STATUS_R,
} pdsh_msg_type_t;
typedef enum { PDSH_DIR_C2S, PDSH_DIR_S2C } pdsh_msg_dir_t;
typedef enum {
    PDSH_ERR_NONE = 0,
    PDSH_ERR_MALFORMED,
    PDSH_ERR_LIMIT,
    PDSH_ERR_BAD_SEQUENCE,
    PDSH_ERR_BAD_CHALLENGE,
    PDSH_ERR_NOT_READY,
    PDSH_ERR_RECORD_MISMATCH,
    PDSH_ERR_REVOKED,
    PDSH_ERR_STORAGE,
    PDSH_ERR_TIMEOUT,
    PDSH_ERR_INTERNAL,
    PDSH_ERR_UNKNOWN_TASK,
    PDSH_ERR_INVALID_TRANSITION,
    PDSH_ERR_CONFLICT,
    PDSH_ERR_WRONG_OWNER,
} pdsh_ss_error_t;
const char *pdsh_ss_error_name(pdsh_ss_error_t code);
bool pdsh_ss_error_fatal(pdsh_ss_error_t code);

typedef struct {
    pdsh_msg_type_t type;
    uint32_t seq; /* c2s requests */
    uint32_t re;  /* s2c and err */
    const char *device, *phone, *eid, *cc, *sc, *id, *idem;
    pdsh_ss_error_t code;
    const cJSON *output, *truncated, *failure; /* complete / fail */
    cJSON *root;                                /* owned */
} pdsh_msg_t;
/* Full §7.2 decode: UTF-8, no BOM, exactly one object, no duplicate names, no
 * NUL or unpaired surrogate, integers only, closed members, direction. */
bool pdsh_msg_decode(const uint8_t *payload, size_t n, pdsh_msg_dir_t dir, pdsh_msg_t *out);
void pdsh_msg_free(pdsh_msg_t *msg);
/* Strict RFC 8259 lexical check used before cJSON parsing. */
bool pdsh_json_strict(const uint8_t *text, size_t n);

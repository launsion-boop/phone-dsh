// SPDX-License-Identifier: MIT
/* Offline enrollment: console grammar, board state machine and the durable
 * board record pdsh_enr/rec_v1 (ble-secure-session.md §3.2, §3.3, §4.2).
 *
 * Host-buildable core. How the console is reached and how enrollment mode is
 * entered on the device are behind the ops seam (pending secure-session-v2,
 * review item H1); this file does not open a console by itself. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "nvs.h"

#define PDSH_ENROLL_LINE_MAX 384
#define PDSH_ENROLL_PRESS_TIMEOUT_MS 30000u
#define PDSH_ENROLL_CONTEXT_TIMEOUT_MS 120000u
#define PDSH_ENROLL_DEBOUNCE_MS 50u

typedef enum {
    PDSH_ENR_NONE,
    PDSH_ENR_COMMITTED,
    PDSH_ENR_REVOKED,
    PDSH_ENR_KEY_LOST,
    PDSH_ENR_KEY_UNAVAILABLE,
    PDSH_ENR_RECORD_CORRUPT,
} pdsh_enroll_state_t;

typedef enum { PDSH_IDENTITY_OK, PDSH_IDENTITY_KEY_LOST, PDSH_IDENTITY_UNAVAILABLE } pdsh_identity_status_t;

typedef struct {
    pdsh_enroll_state_t state;
    char device[65]; /* bare fingerprint hex; empty when the key is lost/unavailable */
    char phone[65];  /* committed/revoked only */
    char eid[33];
    uint32_t rev;
} pdsh_enroll_durable_t;

typedef struct {
    uint64_t (*now_ms)(void);
    void (*random)(uint8_t *out, size_t n);
    bool button_available;
    /* One complete response line without the LF. */
    void (*write_line)(const char *line);
    /* Current device key: fills fp (64 hex) when OK. */
    pdsh_identity_status_t (*identity_probe)(char fp[65]);
    /* Erases rec_v1 and the device key, generates and persists a new key. */
    bool (*identity_reset)(char fp[65]);
    /* Called after the RAM revocation flag is set (closes live sessions). */
    void (*revoked)(void);
} pdsh_enroll_ops_t;

/* Boot: classify durable state from the identity probe and rec_v1. ctx idle. */
bool pdsh_enroll_init(const pdsh_enroll_ops_t *ops, nvs_handle_t record_namespace);
/* Console bytes (any split); complete LF-terminated lines are processed. */
void pdsh_enroll_feed(const uint8_t *data, size_t n);
/* Deadline processing (context 120 s, press 30 s). */
void pdsh_enroll_tick(void);
/* Button level sample (true = pressed). Returns true while the button is
 * owned by enrollment (press wait or a consumed press): the caller must then
 * not apply its ordinary button meaning. */
bool pdsh_enroll_button(bool pressed);
void pdsh_enroll_durable(pdsh_enroll_durable_t *out);
const char *pdsh_enroll_ctx_name(void);
/* Session eligibility (§4.4, §8.3): committed record and no RAM revocation. */
bool pdsh_enroll_session_record(pdsh_enroll_durable_t *out);
/* Serialises a session's authority check with enrollment changes. */
void pdsh_enroll_lock(void);
void pdsh_enroll_unlock(void);

/* ---- grammar (exposed for the shared line fixtures) ---- */
typedef struct {
    bool addressed;
    bool valid;
    char echo[16];  /* known verb or "-" for an invalid addressed line */
    char verb[16];
    int fields;
    char name[6][10];
    char value[6][160];
} pdsh_enroll_line_t;
/* Host→board line content (LF removed, CR still present). */
void pdsh_enroll_parse_command(const uint8_t *line, size_t n, pdsh_enroll_line_t *out);
/* Board→host response grammar check (LF removed). */
void pdsh_enroll_parse_response(const uint8_t *line, size_t n, pdsh_enroll_line_t *out);
/* Prints a parsed response; returns length or 0. */
size_t pdsh_enroll_format(const pdsh_enroll_line_t *line, char *out, size_t cap);

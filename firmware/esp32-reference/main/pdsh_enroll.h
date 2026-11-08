// SPDX-License-Identifier: MIT
/* Offline enrollment: console grammar, board state machine and the durable
 * board record pdsh_enr/rec_v1 (ble-secure-session.md §3.2, §3.3, §4.2).
 *
 * secure-session-v2: authority-changing verbs need enrollment mode, entered
 * only by a 5 s hold of the enrollment button (no host command arms), shown on
 * a dedicated indicator, bounded to an absolute 300 s window and left on every
 * error and every completed action; confirmation is a separate 3 s hold whose
 * press edge follows the `press` line. Host-buildable; the device supplies the
 * console bytes, button samples, clock, RNG and indicator through ops. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "nvs.h"

#define PDSH_ENROLL_LINE_MAX 384
#define PDSH_ENROLL_PRESS_TIMEOUT_MS 30000u
#define PDSH_ENROLL_WINDOW_MS 300000u
#define PDSH_ENROLL_ARM_HOLD_MS 5000u
#define PDSH_ENROLL_CONFIRM_HOLD_MS 3000u
#define PDSH_ENROLL_DEBOUNCE_MS 50u

typedef enum { PDSH_INDICATOR_OFF, PDSH_INDICATOR_ARMED, PDSH_INDICATOR_CONFIRM } pdsh_indicator_t;
/* pdsh_enroll_button() result flags. */
#define PDSH_BUTTON_LEGACY_EDGE 1u /* debounced press edge with its ordinary meaning */
#define PDSH_BUTTON_OWNED 2u       /* enrollment owns the button: no ordinary meaning */

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
    /* CSPRNG draw; false when no entropy source is active (nothing drawn). */
    bool (*random)(uint8_t *out, size_t n);
    bool button_available;
    bool indicator_available; /* dedicated output, never the light.* LED */
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
/* Deadline processing (press 30 s, window 300 s). */
void pdsh_enroll_tick(void);
/* Button level sample (true = pressed); returns PDSH_BUTTON_* flags. The
 * caller opens the pairing window / emits button.pressed only on
 * PDSH_BUTTON_LEGACY_EDGE. */
unsigned pdsh_enroll_button(bool pressed);
pdsh_indicator_t pdsh_enroll_indicator(void);
/* Indicator output level for the pattern (off, 1 Hz, 4 Hz) at now_ms. */
bool pdsh_enroll_indicator_level(uint64_t now_ms);
const char *pdsh_enroll_mode_name(void);
/* Re-reads rec_v1 (test hook for record replacement; harmless at runtime). */
void pdsh_enroll_reload_durable(void);
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
    char name[7][10];
    char value[7][160];
} pdsh_enroll_line_t;
/* Host→board line content (LF removed, CR still present). */
void pdsh_enroll_parse_command(const uint8_t *line, size_t n, pdsh_enroll_line_t *out);
/* Board→host response grammar check (LF removed). */
void pdsh_enroll_parse_response(const uint8_t *line, size_t n, pdsh_enroll_line_t *out);
/* Prints a parsed response; returns length or 0. */
size_t pdsh_enroll_format(const pdsh_enroll_line_t *line, char *out, size_t cap);

// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "cJSON.h"
#include "pdsh_enroll.h"


/* Loads the device identity key from NVS. It is generated only when neither
 * the key nor an enrollment record exists (§4.2: otherwise key_lost).
 * Returns false if the key is unavailable; identity proof then fails closed. */
bool pdsh_identity_init(void);
bool pdsh_identity_ready(void);
/* §4.2 classification result of the last init/reset; fp is the device
 * fingerprint (64 hex) when OK. */
pdsh_identity_status_t pdsh_identity_probe(char fp_hex[65]);
/* Erases pdsh_enr/rec_v1 and pdsh_id/priv, generates and persists a new key. */
bool pdsh_identity_reset(char fp_hex[65]);
/* PSA key handle of the device key (0 when unavailable). */
uint32_t pdsh_identity_key(void); /* psa_key_id_t */
/* Returns an owned JSON object {"pubkey": 130 hex, "signature": 128 hex} for a
 * 64-character lowercase hex nonce, or NULL when the nonce or key is invalid. */
cJSON *pdsh_identity_prove(const char *nonce_hex);

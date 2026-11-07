// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "cJSON.h"

/* Loads the device identity key from NVS, generating it on first use.
 * Returns false if the key is unavailable; identity proof then fails closed. */
bool pdsh_identity_init(void);
bool pdsh_identity_ready(void);
/* Returns an owned JSON object {"pubkey": 130 hex, "signature": 128 hex} for a
 * 64-character lowercase hex nonce, or NULL when the nonce or key is invalid. */
cJSON *pdsh_identity_prove(const char *nonce_hex);

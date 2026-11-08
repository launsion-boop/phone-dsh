// SPDX-License-Identifier: MIT
/* secure-session-v1 pinned self-signed certificates (ble-secure-session.md §6.2). */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "psa/crypto.h"

#define PDSH_CERT_MAX_DER 1024

typedef enum {
    PDSH_CERT_OK = 0,
    PDSH_CERT_NO_CERTIFICATE,
    PDSH_CERT_CHAIN_LENGTH,
    PDSH_CERT_OVERSIZE,
    PDSH_CERT_MALFORMED,
    PDSH_CERT_CURVE,
    PDSH_CERT_PIN_MISMATCH,
    PDSH_CERT_SIGNATURE_ALGORITHM,
    PDSH_CERT_BAD_SELF_SIGNATURE,
    PDSH_CERT_CA_TRUE,
    PDSH_CERT_KEY_USAGE,
    PDSH_CERT_EKU_PRESENT,
    PDSH_CERT_UNKNOWN_CRITICAL_EXTENSION,
    PDSH_CERT_INTERNAL,
} pdsh_cert_status_t;

const char *pdsh_cert_status_name(pdsh_cert_status_t status);
/* Applies §6.2 rules 1-5 in order to a received certificate list. The pin is
 * the expected 64-hex fingerprint. Dates, names, serial and non-critical
 * unknown extensions are not evaluated. */
pdsh_cert_status_t pdsh_cert_verify_chain(const uint8_t *const *der, const size_t *len, size_t count,
                                          const char *expected_pin);
/* Builds the §6.2 producer-profile certificate for a P-256 PSA key pair. The
 * DER is written at the start of out; *len receives its size. */
bool pdsh_cert_build(psa_key_id_t key, bool device, uint8_t *out, size_t cap, size_t *len);

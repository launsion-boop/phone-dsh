// SPDX-License-Identifier: MIT
#pragma once
#include <CommonCrypto/CommonDigest.h>
#define PSA_SUCCESS 0
#define PSA_ALG_SHA_256 1
static inline int psa_crypto_init(void) { return 0; }
static inline int psa_hash_compute(int algo, const uint8_t *p, size_t n, uint8_t *out, size_t cap,
                                   size_t *len) {
    (void)algo;
    if (cap < 32)
        return -1;
    CC_SHA256(p, (CC_LONG)n, out);
    *len = 32;
    return 0;
}

// SPDX-License-Identifier: MIT
#pragma once
#include <stddef.h>
#include <stdint.h>
#define PSA_SUCCESS 0
#define PSA_ALG_SHA_256 1
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
static inline void pdsh_test_sha256(const uint8_t *p, size_t n, uint8_t *out) {
    CC_SHA256(p, (CC_LONG)n, out);
}
#else
/* Portable FIPS 180-4 SHA-256 so the host tests also build on Linux. */
static inline uint32_t pdsh_test_ror(uint32_t x, int r) { return (x >> r) | (x << (32 - r)); }
static inline void pdsh_test_sha256_block(uint32_t h[8], const uint8_t b[64]) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2};
    uint32_t w[64], v[8];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)b[i * 4] << 24 | (uint32_t)b[i * 4 + 1] << 16 |
               (uint32_t)b[i * 4 + 2] << 8 | b[i * 4 + 3];
    for (int i = 16; i < 64; i++)
        w[i] = w[i - 16] + (pdsh_test_ror(w[i - 15], 7) ^ pdsh_test_ror(w[i - 15], 18) ^
                            (w[i - 15] >> 3)) +
               w[i - 7] +
               (pdsh_test_ror(w[i - 2], 17) ^ pdsh_test_ror(w[i - 2], 19) ^ (w[i - 2] >> 10));
    for (int i = 0; i < 8; i++)
        v[i] = h[i];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = v[7] +
                      (pdsh_test_ror(v[4], 6) ^ pdsh_test_ror(v[4], 11) ^ pdsh_test_ror(v[4], 25)) +
                      ((v[4] & v[5]) ^ (~v[4] & v[6])) + k[i] + w[i];
        uint32_t t2 = (pdsh_test_ror(v[0], 2) ^ pdsh_test_ror(v[0], 13) ^ pdsh_test_ror(v[0], 22)) +
                      ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        for (int j = 7; j > 0; j--)
            v[j] = v[j - 1];
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (int i = 0; i < 8; i++)
        h[i] += v[i];
}
static inline void pdsh_test_sha256(const uint8_t *p, size_t n, uint8_t *out) {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint8_t b[64];
    size_t i = 0;
    for (; n - i >= 64; i += 64)
        pdsh_test_sha256_block(h, p + i);
    size_t r = n - i;
    for (size_t j = 0; j < r; j++)
        b[j] = p[i + j];
    b[r++] = 0x80;
    if (r > 56) {
        while (r < 64)
            b[r++] = 0;
        pdsh_test_sha256_block(h, b);
        r = 0;
    }
    while (r < 56)
        b[r++] = 0;
    uint64_t bits = (uint64_t)n * 8;
    for (int j = 0; j < 8; j++)
        b[56 + j] = (uint8_t)(bits >> (56 - 8 * j));
    pdsh_test_sha256_block(h, b);
    for (int j = 0; j < 32; j++)
        out[j] = (uint8_t)(h[j / 4] >> (24 - 8 * (j % 4)));
}
#endif
static inline int psa_crypto_init(void) { return 0; }
static inline int psa_hash_compute(int algo, const uint8_t *p, size_t n, uint8_t *out, size_t cap,
                                   size_t *len) {
    (void)algo;
    if (cap < 32)
        return -1;
    pdsh_test_sha256(p, n, out);
    *len = 32;
    return 0;
}

// SPDX-License-Identifier: MIT
/* Device identity for the BLE task binding (PC-20261106-device-identity-tofu).
 * One ECDSA P-256 key per device. Identity = "ble:" + SHA-256 of the 65-byte
 * uncompressed public key, computed by the phone. The device only signs a
 * phone nonce; it never sends a claimed identity. */
#include <stdio.h>
#include <string.h>
#include "nvs.h"
#include "psa/crypto.h"
#include "pdsh_identity.h"

#define IDENTITY_DOMAIN "phoneDSH BLE identity v1"
#define PUB_LEN 65
#define PRIV_LEN 32
#define SIG_LEN 64

static psa_key_id_t key_id = 0;
static uint8_t pub[PUB_LEN];
static bool ready_flag;

static bool load_or_generate_private(uint8_t priv[PRIV_LEN]) {
    nvs_handle_t h;
    if (nvs_open("pdsh_id", NVS_READWRITE, &h) != ESP_OK) return false;
    size_t len = PRIV_LEN;
    esp_err_t err = nvs_get_blob(h, "priv", priv, &len);
    if (err == ESP_OK && len == PRIV_LEN) { nvs_close(h); return true; }
    if (err != ESP_ERR_NVS_NOT_FOUND) { nvs_close(h); return false; }
    /* First boot: generate with the PSA RNG, then persist before use. */
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_key_id_t generated = 0;
    if (psa_generate_key(&attr, &generated) != PSA_SUCCESS) { nvs_close(h); return false; }
    size_t out = 0;
    psa_status_t st = psa_export_key(generated, priv, PRIV_LEN, &out);
    psa_destroy_key(generated);
    if (st != PSA_SUCCESS || out != PRIV_LEN) { nvs_close(h); return false; }
    if (nvs_set_blob(h, "priv", priv, PRIV_LEN) != ESP_OK || nvs_commit(h) != ESP_OK) {
        nvs_close(h);
        return false;
    }
    nvs_close(h);
    return true;
}

bool pdsh_identity_init(void) {
    if (ready_flag) return true;
    uint8_t priv[PRIV_LEN];
    if (psa_crypto_init() != PSA_SUCCESS || !load_or_generate_private(priv)) {
        memset(priv, 0, sizeof(priv));
        return false;
    }
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_status_t st = psa_import_key(&attr, priv, PRIV_LEN, &key_id);
    memset(priv, 0, sizeof(priv));
    if (st != PSA_SUCCESS) return false;
    size_t len = 0;
    if (psa_export_public_key(key_id, pub, PUB_LEN, &len) != PSA_SUCCESS || len != PUB_LEN) {
        psa_destroy_key(key_id);
        key_id = 0;
        return false;
    }
    ready_flag = true;
    return true;
}

bool pdsh_identity_ready(void) { return ready_flag; }

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/* Strict lowercase hex: exact length, no signs, no whitespace. */
static bool hex_decode(const char *text, uint8_t *out, size_t out_len) {
    if (strlen(text) != out_len * 2) return false;
    for (size_t i = 0; i < out_len; i++) {
        int hi = nibble(text[2 * i]), lo = nibble(text[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

static void hex_encode(const uint8_t *in, size_t len, char *out) {
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[2 * i] = digits[in[i] >> 4];
        out[2 * i + 1] = digits[in[i] & 15];
    }
    out[2 * len] = 0;
}

cJSON *pdsh_identity_prove(const char *nonce_hex) {
    if (!ready_flag || !nonce_hex) return NULL;
    uint8_t nonce[32];
    if (!hex_decode(nonce_hex, nonce, sizeof(nonce))) return NULL;

    /* Message: domain NUL nonce NUL pubkey. The phone verifies the same bytes. */
    const size_t domain_len = sizeof(IDENTITY_DOMAIN) - 1;
    uint8_t msg[sizeof(IDENTITY_DOMAIN) + 1 + 32 + 1 + PUB_LEN];
    size_t n = 0;
    memcpy(msg + n, IDENTITY_DOMAIN, domain_len); n += domain_len;
    msg[n++] = 0;
    memcpy(msg + n, nonce, 32); n += 32;
    msg[n++] = 0;
    memcpy(msg + n, pub, PUB_LEN); n += PUB_LEN;

    uint8_t digest[32], sig[SIG_LEN];
    size_t digest_len = 0, sig_len = 0;
    if (psa_hash_compute(PSA_ALG_SHA_256, msg, n, digest, sizeof(digest), &digest_len) != PSA_SUCCESS ||
        digest_len != 32)
        return NULL;
    if (psa_sign_hash(key_id, PSA_ALG_ECDSA(PSA_ALG_SHA_256), digest, sizeof(digest),
                      sig, sizeof(sig), &sig_len) != PSA_SUCCESS || sig_len != SIG_LEN)
        return NULL;

    char pub_hex[PUB_LEN * 2 + 1], sig_hex[SIG_LEN * 2 + 1];
    hex_encode(pub, PUB_LEN, pub_hex);
    hex_encode(sig, SIG_LEN, sig_hex);
    cJSON *o = cJSON_CreateObject();
    if (!o) return NULL;
    cJSON_AddStringToObject(o, "pubkey", pub_hex);
    cJSON_AddStringToObject(o, "signature", sig_hex);
    return o;
}

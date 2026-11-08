// SPDX-License-Identifier: MIT
/* Device identity (ble-secure-session.md §2, §4.2). One ECDSA P-256 key per
 * device; device ID = "ble:" + SHA-256 of the 65-byte uncompressed public key.
 * The key signs only TLS 1.3 CertificateVerify and the board's own
 * certificate, always deterministically (RFC 6979: the PSA key policy permits
 * only PSA_ALG_DETERMINISTIC_ECDSA). It is generated only while an ESP32-S3
 * entropy source is active (BLE controller RF, or a bootloader_random bracket),
 * and the source is logged. */
#include <stdio.h>
#include <string.h>
#include "nvs.h"
#include "psa/crypto.h"
#include "pdsh_identity.h"
#include "pdsh_secure_msg.h"

#define IDENTITY_DOMAIN "phoneDSH BLE identity v1"
#define PUB_LEN 65
#define PRIV_LEN 32
#define SIG_LEN 64

static psa_key_id_t key_id = 0;
static uint8_t pub[PUB_LEN];
static bool ready_flag;
static pdsh_identity_status_t status = PDSH_IDENTITY_UNAVAILABLE;

/* An enrollment record (any content, even corrupt) proves authority existed. */
static bool enrollment_record_present(void) {
    nvs_handle_t h;
    if (nvs_open("pdsh_enr", NVS_READWRITE, &h) != ESP_OK) return true; /* unknown: fail closed */
    char buffer[512];
    size_t len = sizeof(buffer);
    esp_err_t err = nvs_get_blob(h, "rec_v1", buffer, &len);
    nvs_close(h);
    return err != ESP_ERR_NVS_NOT_FOUND;
}

#ifdef ESP_PLATFORM
#include "bootloader_random.h"
#include "esp_bt.h"
#include "esp_log.h"
#include "esp_random.h"
static bool bracketed;
/* §2 randomness: the RF subsystem (BLE controller) is on, else the SAR-ADC
 * source is bracketed with bootloader_random_enable/disable. */
const char *pdsh_entropy_begin(void) {
    if (esp_bt_controller_get_status() == ESP_BT_CONTROLLER_STATUS_ENABLED) return "bt-controller-rf";
    bootloader_random_enable();
    bracketed = true;
    return "bootloader_random_enable";
}
void pdsh_entropy_end(void) {
    if (bracketed) bootloader_random_disable();
    bracketed = false;
}
bool pdsh_entropy_random(uint8_t *out, size_t n) {
    /* Runtime draws (eid, sc) require the RF source; no ADC bracket while the
     * radio stack runs. */
    if (esp_bt_controller_get_status() != ESP_BT_CONTROLLER_STATUS_ENABLED) return false;
    esp_fill_random(out, n);
    return true;
}
#define LOG_SOURCE(src) ESP_LOGI("pdsh", "device key generated with entropy source %s", src)
#else
const char *pdsh_entropy_begin(void) { return "host-csprng"; }
void pdsh_entropy_end(void) {}
bool pdsh_entropy_random(uint8_t *out, size_t n) { return psa_generate_random(out, n) == PSA_SUCCESS; }
#define LOG_SOURCE(src) ((void)(src))
#endif

static void key_attributes(psa_key_attributes_t *attr) {
    psa_set_key_usage_flags(attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_SIGN_MESSAGE | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(attr, PSA_ALG_DETERMINISTIC_ECDSA(PSA_ALG_SHA_256));
    psa_set_key_type(attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(attr, 256);
}

static bool generate_and_store(nvs_handle_t h, uint8_t priv[PRIV_LEN]) {
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_DETERMINISTIC_ECDSA(PSA_ALG_SHA_256));
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_key_id_t generated = 0;
    const char *source = pdsh_entropy_begin();
    psa_status_t gen = psa_generate_key(&attr, &generated);
    pdsh_entropy_end();
    if (gen != PSA_SUCCESS) return false;
    LOG_SOURCE(source);
    size_t out = 0;
    psa_status_t st = psa_export_key(generated, priv, PRIV_LEN, &out);
    psa_destroy_key(generated);
    if (st != PSA_SUCCESS || out != PRIV_LEN) return false;
    if (nvs_set_blob(h, "priv", priv, PRIV_LEN) != ESP_OK || nvs_commit(h) != ESP_OK) return false;
    uint8_t back[PRIV_LEN];
    size_t len = sizeof(back);
    bool same = nvs_get_blob(h, "priv", back, &len) == ESP_OK && len == PRIV_LEN && !memcmp(back, priv, PRIV_LEN);
    memset(back, 0, sizeof(back));
    return same; /* read back before use */
}

/* ble-secure-session.md §4.2: NOT_FOUND generates only when no enrollment
 * record exists; with a record the key is lost and never regenerated here. */
static pdsh_identity_status_t load_private(uint8_t priv[PRIV_LEN]) {
    nvs_handle_t h;
    if (nvs_open("pdsh_id", NVS_READWRITE, &h) != ESP_OK) return PDSH_IDENTITY_UNAVAILABLE;
    size_t len = PRIV_LEN;
    esp_err_t err = nvs_get_blob(h, "priv", priv, &len);
    pdsh_identity_status_t result = PDSH_IDENTITY_UNAVAILABLE;
    if (err == ESP_OK && len == PRIV_LEN) result = PDSH_IDENTITY_OK;
    else if (err == ESP_ERR_NVS_NOT_FOUND)
        result = enrollment_record_present() ? PDSH_IDENTITY_KEY_LOST
                 : generate_and_store(h, priv) ? PDSH_IDENTITY_OK : PDSH_IDENTITY_UNAVAILABLE;
    nvs_close(h);
    return result;
}

static bool import_private(const uint8_t priv[PRIV_LEN]) {
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    key_attributes(&attr);
    psa_key_id_t id = 0;
    if (psa_import_key(&attr, priv, PRIV_LEN, &id) != PSA_SUCCESS) return false;
    size_t len = 0;
    if (psa_export_public_key(id, pub, PUB_LEN, &len) != PSA_SUCCESS || len != PUB_LEN) {
        psa_destroy_key(id);
        return false;
    }
    if (key_id) psa_destroy_key(key_id);
    key_id = id;
    return true;
}

bool pdsh_identity_init(void) {
    if (ready_flag) return true;
    uint8_t priv[PRIV_LEN];
    if (psa_crypto_init() != PSA_SUCCESS) {
        status = PDSH_IDENTITY_UNAVAILABLE;
        return false;
    }
    status = load_private(priv);
    if (status == PDSH_IDENTITY_OK && !import_private(priv)) status = PDSH_IDENTITY_UNAVAILABLE;
    memset(priv, 0, sizeof(priv));
    ready_flag = status == PDSH_IDENTITY_OK;
    return ready_flag;
}

pdsh_identity_status_t pdsh_identity_probe(char fp_hex[65]) {
    if (!ready_flag) return status;
    return pdsh_fingerprint(pub, fp_hex) ? PDSH_IDENTITY_OK : PDSH_IDENTITY_UNAVAILABLE;
}

uint32_t pdsh_identity_key(void) { return ready_flag ? key_id : 0; }

bool pdsh_identity_reset(char fp_hex[65]) {
    nvs_handle_t enr, id;
    if (nvs_open("pdsh_enr", NVS_READWRITE, &enr) != ESP_OK) return false;
    esp_err_t e1 = nvs_erase_key(enr, "rec_v1");
    bool ok = (e1 == ESP_OK || e1 == ESP_ERR_NVS_NOT_FOUND) && nvs_commit(enr) == ESP_OK;
    nvs_close(enr);
    if (!ok || nvs_open("pdsh_id", NVS_READWRITE, &id) != ESP_OK) return false;
    esp_err_t e2 = nvs_erase_key(id, "priv");
    uint8_t priv[PRIV_LEN];
    ready_flag = false;
    status = PDSH_IDENTITY_UNAVAILABLE;
    ok = (e2 == ESP_OK || e2 == ESP_ERR_NVS_NOT_FOUND) && nvs_commit(id) == ESP_OK && generate_and_store(id, priv);
    nvs_close(id);
    if (ok) ok = import_private(priv);
    memset(priv, 0, sizeof(priv));
    if (ok) {
        status = PDSH_IDENTITY_OK;
        ready_flag = true;
        ok = pdsh_fingerprint(pub, fp_hex);
    }
    return ok;
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
    if (psa_sign_hash(key_id, PSA_ALG_DETERMINISTIC_ECDSA(PSA_ALG_SHA_256), digest, sizeof(digest),
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

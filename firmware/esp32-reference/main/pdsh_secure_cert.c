// SPDX-License-Identifier: MIT
#include "pdsh_secure_cert.h"
#include "pdsh_secure_msg.h"
#include "mbedtls/pk.h"
#include "mbedtls/psa_util.h"
#include "mbedtls/x509_crt.h"
#include <string.h>

static const char *const names[] = {"ok", "no_certificate", "chain_length", "oversize", "malformed",
                                    "curve", "pin_mismatch", "signature_algorithm", "bad_self_signature",
                                    "ca_true", "key_usage", "eku_present", "unknown_critical_extension",
                                    "internal"};
const char *pdsh_cert_status_name(pdsh_cert_status_t status) {
    return (unsigned)status < sizeof(names) / sizeof(names[0]) ? names[status] : "internal";
}

/* Minimal strict DER reader for the fields the profile inspects. */
typedef struct {
    const uint8_t *p, *end;
} der_t;
static bool tlv(der_t *d, uint8_t *tag, der_t *content, const uint8_t **start) {
    if (start) *start = d->p;
    if (d->end - d->p < 2) return false;
    *tag = *d->p++;
    size_t len = *d->p++;
    if (len & 0x80) {
        size_t bytes = len & 0x7f;
        if (bytes == 0 || bytes > 2 || (size_t)(d->end - d->p) < bytes) return false;
        len = 0;
        for (size_t i = 0; i < bytes; i++) len = len << 8 | *d->p++;
        if (len < 0x80 || (bytes == 2 && len < 0x100)) return false; /* minimal length */
    }
    if ((size_t)(d->end - d->p) < len) return false;
    content->p = d->p;
    content->end = d->p + len;
    d->p += len;
    return true;
}
static bool expect(der_t *d, uint8_t want, der_t *content) {
    uint8_t tag;
    return tlv(d, &tag, content, NULL) && tag == want;
}
static bool same(const der_t *d, const uint8_t *bytes, size_t n) {
    return (size_t)(d->end - d->p) == n && !memcmp(d->p, bytes, n);
}

static const uint8_t oid_ec_public_key[] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01};
static const uint8_t oid_prime256v1[] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07};
static const uint8_t oid_ecdsa_sha256[] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02};
static const uint8_t oid_basic_constraints[] = {0x55, 0x1d, 0x13};
static const uint8_t oid_key_usage[] = {0x55, 0x1d, 0x0f};
static const uint8_t oid_ext_key_usage[] = {0x55, 0x1d, 0x25};

typedef struct {
    der_t tbs_tlv, sig_alg, sig_value, spki, exts;
    bool has_exts;
} cert_parts_t;
static bool split(const uint8_t *der, size_t len, cert_parts_t *parts) {
    memset(parts, 0, sizeof(*parts));
    der_t all = {der, der + len}, cert, tbs, sig_alg, bits, scratch;
    const uint8_t *tbs_start;
    uint8_t tag;
    if (!expect(&all, 0x30, &cert) || all.p != all.end) return false;
    if (!tlv(&cert, &tag, &tbs, &tbs_start) || tag != 0x30) return false;
    parts->tbs_tlv.p = tbs_start;
    parts->tbs_tlv.end = tbs.end;
    if (!expect(&cert, 0x30, &sig_alg) || !expect(&cert, 0x03, &bits) || cert.p != cert.end) return false;
    parts->sig_alg = sig_alg;
    parts->sig_value = bits;
    /* tbsCertificate: [0] version, serial, signature, issuer, validity, subject, spki, ... */
    der_t version, number;
    /* X.509 v3 only: [0] EXPLICIT INTEGER 2 must be present. */
    if (!expect(&tbs, 0xa0, &version) || !expect(&version, 0x02, &number) || version.p != version.end ||
        number.end - number.p != 1 || *number.p != 2)
        return false;
    if (!expect(&tbs, 0x02, &scratch) || !expect(&tbs, 0x30, &scratch) ||
        !expect(&tbs, 0x30, &scratch) || !expect(&tbs, 0x30, &scratch) || !expect(&tbs, 0x30, &scratch) ||
        !expect(&tbs, 0x30, &parts->spki))
        return false;
    while (tbs.p < tbs.end) {
        der_t content;
        if (!tlv(&tbs, &tag, &content, NULL)) return false;
        if (tag == 0xa3) {
            if (!expect(&content, 0x30, &parts->exts) || content.p != content.end) return false;
            parts->has_exts = true;
        } else if (tag != 0x81 && tag != 0x82)
            return false;
    }
    return true;
}

static pdsh_cert_status_t spki_point(der_t spki, uint8_t point[65]) {
    der_t alg, oid, params, bits;
    if (!expect(&spki, 0x30, &alg) || !expect(&spki, 0x03, &bits) || spki.p != spki.end) return PDSH_CERT_MALFORMED;
    if (!expect(&alg, 0x06, &oid) || !same(&oid, oid_ec_public_key, sizeof(oid_ec_public_key)))
        return PDSH_CERT_CURVE;
    if (!expect(&alg, 0x06, &params) || alg.p != alg.end ||
        !same(&params, oid_prime256v1, sizeof(oid_prime256v1)))
        return PDSH_CERT_CURVE;
    if (bits.end - bits.p != 66 || bits.p[0] != 0) return PDSH_CERT_CURVE;
    memcpy(point, bits.p + 1, 65);
    return pdsh_pubkey_check(point, 65) == PDSH_KEY_OK ? PDSH_CERT_OK : PDSH_CERT_CURVE;
}

static pdsh_cert_status_t self_signature(const cert_parts_t *parts, const uint8_t point[65]) {
    der_t alg = parts->sig_alg, oid;
    if (!expect(&alg, 0x06, &oid) || alg.p != alg.end ||
        !same(&oid, oid_ecdsa_sha256, sizeof(oid_ecdsa_sha256)))
        return PDSH_CERT_SIGNATURE_ALGORITHM;
    der_t bits = parts->sig_value;
    if (bits.end - bits.p < 2 || bits.p[0] != 0) return PDSH_CERT_BAD_SELF_SIGNATURE;
    uint8_t raw[64];
    size_t raw_len = 0;
    if (mbedtls_ecdsa_der_to_raw(256, bits.p + 1, (size_t)(bits.end - bits.p - 1), raw, sizeof(raw), &raw_len) ||
        raw_len != 64)
        return PDSH_CERT_BAD_SELF_SIGNATURE;
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_PUBLIC_KEY(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_VERIFY_MESSAGE);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_key_id_t key = 0;
    if (psa_import_key(&attr, point, 65, &key) != PSA_SUCCESS) return PDSH_CERT_INTERNAL;
    psa_status_t st = psa_verify_message(key, PSA_ALG_ECDSA(PSA_ALG_SHA_256), parts->tbs_tlv.p,
                                         (size_t)(parts->tbs_tlv.end - parts->tbs_tlv.p), raw, 64);
    psa_destroy_key(key);
    return st == PSA_SUCCESS ? PDSH_CERT_OK : PDSH_CERT_BAD_SELF_SIGNATURE;
}

static pdsh_cert_status_t extensions(const cert_parts_t *parts) {
    bool ca = false, key_usage = false, eku = false, unknown_critical = false;
    der_t list = parts->exts;
    while (parts->has_exts && list.p < list.end) {
        der_t ext, oid, value;
        uint8_t tag;
        bool critical = false;
        if (!expect(&list, 0x30, &ext) || !expect(&ext, 0x06, &oid)) return PDSH_CERT_MALFORMED;
        if (!tlv(&ext, &tag, &value, NULL)) return PDSH_CERT_MALFORMED;
        if (tag == 0x01) {
            if (value.end - value.p != 1) return PDSH_CERT_MALFORMED;
            critical = *value.p != 0;
            if (!tlv(&ext, &tag, &value, NULL)) return PDSH_CERT_MALFORMED;
        }
        if (tag != 0x04 || ext.p != ext.end) return PDSH_CERT_MALFORMED;
        if (same(&oid, oid_basic_constraints, sizeof(oid_basic_constraints))) {
            der_t seq, flag;
            if (!expect(&value, 0x30, &seq)) return PDSH_CERT_MALFORMED;
            if (seq.p < seq.end && *seq.p == 0x01) {
                if (!expect(&seq, 0x01, &flag) || flag.end - flag.p != 1) return PDSH_CERT_MALFORMED;
                ca = *flag.p != 0;
            }
        } else if (same(&oid, oid_key_usage, sizeof(oid_key_usage))) {
            der_t bits;
            if (!expect(&value, 0x03, &bits) || bits.end - bits.p < 1) return PDSH_CERT_MALFORMED;
            key_usage = bits.end - bits.p >= 2 && (bits.p[1] & 0x80);
        } else if (same(&oid, oid_ext_key_usage, sizeof(oid_ext_key_usage))) {
            eku = true;
        } else if (critical) {
            unknown_critical = true;
        }
    }
    if (ca) return PDSH_CERT_CA_TRUE;
    if (!key_usage) return PDSH_CERT_KEY_USAGE;
    if (eku) return PDSH_CERT_EKU_PRESENT;
    if (unknown_critical) return PDSH_CERT_UNKNOWN_CRITICAL_EXTENSION;
    return PDSH_CERT_OK;
}

pdsh_cert_status_t pdsh_cert_verify_chain(const uint8_t *const *der, const size_t *len, size_t count,
                                          const char *expected_pin) {
    if (count == 0) return PDSH_CERT_NO_CERTIFICATE;
    if (count != 1) return PDSH_CERT_CHAIN_LENGTH;
    if (len[0] > PDSH_CERT_MAX_DER) return PDSH_CERT_OVERSIZE;
    if (psa_crypto_init() != PSA_SUCCESS) return PDSH_CERT_INTERNAL;
    /* The application's own DER evaluation decides (§6.2); no library parse
     * result can accept or reject ahead of rules 1-5. */
    cert_parts_t parts;
    if (!split(der[0], len[0], &parts)) return PDSH_CERT_MALFORMED;
    uint8_t point[65];
    pdsh_cert_status_t status = spki_point(parts.spki, point);
    if (status != PDSH_CERT_OK) return status;
    char fp[PDSH_SS_FP_HEX + 1];
    if (!pdsh_fingerprint(point, fp)) return PDSH_CERT_INTERNAL;
    if (!expected_pin || strcmp(fp, expected_pin)) return PDSH_CERT_PIN_MISMATCH;
    status = self_signature(&parts, point);
    if (status != PDSH_CERT_OK) return status;
    return extensions(&parts);
}

bool pdsh_cert_build(psa_key_id_t key, bool device, uint8_t *out, size_t cap, size_t *len) {
    static const uint8_t serial[] = {0x01};
    static const uint8_t basic_constraints[] = {0x30, 0x00};       /* cA FALSE */
    static const uint8_t key_usage[] = {0x03, 0x02, 0x07, 0x80};   /* digitalSignature */
    const char *name = device ? "CN=pdsh-ble-device" : "CN=pdsh-ble-phone";
    mbedtls_pk_context pk;
    mbedtls_x509write_cert w;
    mbedtls_pk_init(&pk);
    mbedtls_x509write_crt_init(&w);
    bool ok = false;
    if (mbedtls_pk_wrap_psa(&pk, key) == 0) {
        mbedtls_x509write_crt_set_version(&w, MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&w, MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&w, &pk);
        mbedtls_x509write_crt_set_issuer_key(&w, &pk);
        int ret = mbedtls_x509write_crt_set_serial_raw(&w, (unsigned char *)serial, sizeof(serial));
        if (!ret) ret = mbedtls_x509write_crt_set_validity(&w, "20260101000000", "99991231235959");
        if (!ret) ret = mbedtls_x509write_crt_set_subject_name(&w, name);
        if (!ret) ret = mbedtls_x509write_crt_set_issuer_name(&w, name);
        if (!ret)
            ret = mbedtls_x509write_crt_set_extension(&w, (const char *)oid_basic_constraints,
                                                      sizeof(oid_basic_constraints), 1, basic_constraints,
                                                      sizeof(basic_constraints));
        if (!ret)
            ret = mbedtls_x509write_crt_set_extension(&w, (const char *)oid_key_usage, sizeof(oid_key_usage), 1,
                                                      key_usage, sizeof(key_usage));
        int n = ret ? ret : mbedtls_x509write_crt_der(&w, out, cap);
        if (n > 0 && (size_t)n <= PDSH_CERT_MAX_DER) {
            memmove(out, out + cap - (size_t)n, (size_t)n);
            *len = (size_t)n;
            ok = true;
        }
    }
    mbedtls_x509write_crt_free(&w);
    mbedtls_pk_free(&pk);
    return ok;
}

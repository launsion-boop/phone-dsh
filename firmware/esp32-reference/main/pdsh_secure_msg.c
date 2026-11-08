// SPDX-License-Identifier: MIT
#include "pdsh_secure_msg.h"
#include "pdsh_task_validate.h"
#include "psa/crypto.h"
#include <stdlib.h>
#include <string.h>

/* ---------------- identifiers ---------------- */

static const char *const key_names[] = {"ok", "not_hex", "uppercase", "length", "not_uncompressed",
                                        "coordinate_range", "not_on_curve", "internal"};
const char *pdsh_key_status_name(pdsh_key_status_t status) {
    return (unsigned)status < sizeof(key_names) / sizeof(key_names[0]) ? key_names[status] : "internal";
}

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
void pdsh_hex_encode(const uint8_t *in, size_t n, char *out) {
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = digits[in[i] >> 4];
        out[2 * i + 1] = digits[in[i] & 15];
    }
    out[2 * n] = 0;
}
bool pdsh_lower_hex(const char *text, size_t length) {
    if (!text || strlen(text) != length) return false;
    for (size_t i = 0; i < length; i++)
        if (nibble(text[i]) < 0) return false;
    return true;
}
bool pdsh_hex_decode(const char *text, uint8_t *out, size_t n) {
    if (!pdsh_lower_hex(text, n * 2)) return false;
    for (size_t i = 0; i < n; i++) out[i] = (uint8_t)(nibble(text[2 * i]) << 4 | nibble(text[2 * i + 1]));
    return true;
}
bool pdsh_device_id_valid(const char *text) {
    return text && !strncmp(text, "ble:", 4) && pdsh_lower_hex(text + 4, PDSH_SS_FP_HEX);
}
bool pdsh_phone_id_valid(const char *text) {
    return text && !strncmp(text, "phone:", 6) && pdsh_lower_hex(text + 6, PDSH_SS_FP_HEX);
}

/* P-256 field prime, big endian. */
static const uint8_t p256_p[32] = {0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0,
                                   0,    0,    0,    0,    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                                   0xff, 0xff, 0xff, 0xff};

pdsh_key_status_t pdsh_pubkey_check(const uint8_t *point, size_t len) {
    if (len != 65) return PDSH_KEY_LENGTH;
    if (point[0] != 0x04) return PDSH_KEY_NOT_UNCOMPRESSED;
    if (memcmp(point + 1, p256_p, 32) >= 0 || memcmp(point + 33, p256_p, 32) >= 0)
        return PDSH_KEY_COORDINATE_RANGE;
    if (psa_crypto_init() != PSA_SUCCESS) return PDSH_KEY_INTERNAL;
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_PUBLIC_KEY(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_VERIFY_HASH);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_key_id_t id = 0;
    psa_status_t st = psa_import_key(&attr, point, 65, &id);
    if (st == PSA_SUCCESS) {
        psa_destroy_key(id);
        return PDSH_KEY_OK;
    }
    return st == PSA_ERROR_INVALID_ARGUMENT ? PDSH_KEY_NOT_ON_CURVE : PDSH_KEY_INTERNAL;
}

pdsh_key_status_t pdsh_pubkey_check_hex(const char *hex, uint8_t point[65]) {
    if (!hex) return PDSH_KEY_NOT_HEX;
    size_t n = strlen(hex);
    bool upper = false;
    for (size_t i = 0; i < n; i++) {
        char c = hex[i];
        if (c >= 'A' && c <= 'F') upper = true;
        else if (nibble(c) < 0) return PDSH_KEY_NOT_HEX;
    }
    if (upper) return PDSH_KEY_UPPERCASE;
    if (n % 2 || n != 130) return PDSH_KEY_LENGTH;
    pdsh_hex_decode(hex, point, 65);
    return pdsh_pubkey_check(point, 65);
}

bool pdsh_fingerprint(const uint8_t point[65], char fp_hex[PDSH_SS_FP_HEX + 1]) {
    uint8_t digest[32];
    size_t len = 0;
    if (psa_crypto_init() != PSA_SUCCESS ||
        psa_hash_compute(PSA_ALG_SHA_256, point, 65, digest, sizeof(digest), &len) != PSA_SUCCESS ||
        len != 32)
        return false;
    pdsh_hex_encode(digest, 32, fp_hex);
    return true;
}

/* ---------------- framing ---------------- */

void pdsh_frame_reset(pdsh_frame_decoder_t *dec) { memset(dec, 0, sizeof(*dec)); }
bool pdsh_frame_pending(const pdsh_frame_decoder_t *dec) { return !dec->failed && dec->have > 0; }

pdsh_frame_result_t pdsh_frame_next(pdsh_frame_decoder_t *dec, const uint8_t **data, size_t *n,
                                    const uint8_t **payload, size_t *payload_len) {
    if (dec->failed) return PDSH_FRAME_LIMIT;
    while (*n) {
        if (dec->have < 2) {
            dec->buf[dec->have++] = **data;
            (*data)++;
            (*n)--;
            if (dec->have == 2) {
                size_t len = dec->buf[0] | (size_t)dec->buf[1] << 8;
                /* The length is judged as soon as both bytes are known. */
                if (len == 0 || len > PDSH_SS_FRAME_MAX) {
                    dec->failed = true;
                    return PDSH_FRAME_LIMIT;
                }
            }
            continue;
        }
        size_t len = dec->buf[0] | (size_t)dec->buf[1] << 8;
        size_t want = 2 + len - dec->have, take = *n < want ? *n : want;
        memcpy(dec->buf + dec->have, *data, take);
        dec->have += take;
        *data += take;
        *n -= take;
        if (dec->have == 2 + len) break;
    }
    if (dec->have >= 2) {
        size_t len = dec->buf[0] | (size_t)dec->buf[1] << 8;
        if (dec->have == 2 + len) {
            *payload = dec->buf + 2;
            *payload_len = len;
            dec->have = 0; /* the payload stays readable until the next call writes */
            return PDSH_FRAME_PAYLOAD;
        }
    }
    return PDSH_FRAME_MORE;
}

bool pdsh_frame_encode(const uint8_t *payload, size_t n, uint8_t *out) {
    if (n == 0 || n > PDSH_SS_FRAME_MAX) return false;
    out[0] = (uint8_t)n;
    out[1] = (uint8_t)(n >> 8);
    memmove(out + 2, payload, n);
    return true;
}

/* ---------------- strict JSON ---------------- */

typedef struct {
    const uint8_t *p, *end;
    int depth;
} lex_t;
static void ws(lex_t *l) {
    while (l->p < l->end && (*l->p == ' ' || *l->p == '\t' || *l->p == '\n' || *l->p == '\r')) l->p++;
}
static int hex4(const uint8_t *p) {
    int v = 0;
    for (int i = 0; i < 4; i++) {
        int c = p[i], d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
                                                    : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (d < 0) return -1;
        v = v << 4 | d;
    }
    return v;
}
static bool lex_string(lex_t *l) {
    if (l->p >= l->end || *l->p != '"') return false;
    l->p++;
    while (l->p < l->end) {
        uint8_t c = *l->p;
        if (c == '"') {
            l->p++;
            return true;
        }
        if (c < 0x20) return false;
        if (c == '\\') {
            if (l->end - l->p < 2) return false;
            uint8_t e = l->p[1];
            if (e == 'u') {
                if (l->end - l->p < 6) return false;
                int u = hex4(l->p + 2);
                if (u < 0 || u == 0) return false; /* NUL is never allowed */
                l->p += 6;
                if (u >= 0xdc00 && u <= 0xdfff) return false;
                if (u >= 0xd800 && u <= 0xdbff) {
                    if (l->end - l->p < 6 || l->p[0] != '\\' || l->p[1] != 'u') return false;
                    int low = hex4(l->p + 2);
                    if (low < 0xdc00 || low > 0xdfff) return false;
                    l->p += 6;
                }
                continue;
            }
            if (!strchr("\"\\/bfnrt", e) || !e) return false;
            l->p += 2;
            continue;
        }
        if (c < 0x80) {
            l->p++;
            continue;
        }
        /* UTF-8 multi-byte sequence, shortest form, no surrogates. */
        size_t width;
        uint32_t cp;
        if (c >= 0xc2 && c <= 0xdf) width = 2, cp = c & 0x1f;
        else if (c >= 0xe0 && c <= 0xef) width = 3, cp = c & 0x0f;
        else if (c >= 0xf0 && c <= 0xf4) width = 4, cp = c & 0x07;
        else return false;
        if ((size_t)(l->end - l->p) < width) return false;
        for (size_t i = 1; i < width; i++) {
            if ((l->p[i] & 0xc0) != 0x80) return false;
            cp = cp << 6 | (l->p[i] & 0x3f);
        }
        if ((width == 3 && cp < 0x800) || (width == 4 && (cp < 0x10000 || cp > 0x10ffff)) ||
            (cp >= 0xd800 && cp <= 0xdfff))
            return false;
        l->p += width;
    }
    return false;
}
static bool lex_value(lex_t *l);
static bool lex_number(lex_t *l) {
    if (l->p < l->end && *l->p == '-') l->p++;
    if (l->p >= l->end) return false;
    if (*l->p == '0') l->p++;
    else if (*l->p >= '1' && *l->p <= '9')
        while (l->p < l->end && *l->p >= '0' && *l->p <= '9') l->p++;
    else return false;
    /* Every number in this profile is an integer: no fraction or exponent. */
    return !(l->p < l->end && (*l->p == '.' || *l->p == 'e' || *l->p == 'E'));
}
static bool lex_literal(lex_t *l, const char *word) {
    size_t n = strlen(word);
    if ((size_t)(l->end - l->p) < n || memcmp(l->p, word, n)) return false;
    l->p += n;
    return true;
}
static bool lex_value(lex_t *l) {
    ws(l);
    if (l->p >= l->end) return false;
    uint8_t c = *l->p;
    if (c == '{' || c == '[') {
        if (++l->depth > 16) return false;
        l->p++;
        ws(l);
        uint8_t close = c == '{' ? '}' : ']';
        if (l->p < l->end && *l->p == close) {
            l->p++;
            l->depth--;
            return true;
        }
        for (;;) {
            if (c == '{') {
                ws(l);
                if (!lex_string(l)) return false;
                ws(l);
                if (l->p >= l->end || *l->p != ':') return false;
                l->p++;
            }
            if (!lex_value(l)) return false;
            ws(l);
            if (l->p >= l->end) return false;
            if (*l->p == ',') {
                l->p++;
                continue;
            }
            if (*l->p != close) return false;
            l->p++;
            l->depth--;
            return true;
        }
    }
    if (c == '"') return lex_string(l);
    if (c == 't') return lex_literal(l, "true");
    if (c == 'f') return lex_literal(l, "false");
    if (c == 'n') return lex_literal(l, "null");
    return lex_number(l);
}
bool pdsh_json_strict(const uint8_t *text, size_t n) {
    lex_t l = {text, text + n, 0};
    ws(&l);
    if (l.p >= l.end || *l.p != '{') return false; /* exactly one object; a BOM fails here */
    if (!lex_value(&l)) return false;
    ws(&l);
    return l.p == l.end;
}

/* ---------------- messages ---------------- */

static const char *const error_names[] = {
    "", "malformed", "limit", "bad_sequence", "bad_challenge", "not_ready", "record_mismatch", "revoked",
    "storage", "timeout", "internal", "unknown_task", "invalid_transition", "conflict", "wrong_owner"};
const char *pdsh_ss_error_name(pdsh_ss_error_t code) {
    return (unsigned)code < sizeof(error_names) / sizeof(error_names[0]) ? error_names[code] : "";
}
bool pdsh_ss_error_fatal(pdsh_ss_error_t code) { return code >= PDSH_ERR_MALFORMED && code <= PDSH_ERR_INTERNAL; }
static pdsh_ss_error_t error_code(const char *name) {
    if (!name) return PDSH_ERR_NONE;
    for (size_t i = 1; i < sizeof(error_names) / sizeof(error_names[0]); i++)
        if (!strcmp(name, error_names[i])) return (pdsh_ss_error_t)i;
    return PDSH_ERR_NONE;
}

static bool exact_members(const cJSON *obj, const char *const *names, size_t n, size_t optional) {
    if (!cJSON_IsObject(obj)) return false;
    size_t seen = 0, required = n - optional;
    const cJSON *v;
    cJSON_ArrayForEach(v, obj) {
        size_t i = 0;
        while (i < n && strcmp(v->string, names[i])) i++;
        if (i == n) return false;
        seen++;
    }
    for (size_t i = 0; i < required; i++)
        if (!cJSON_GetObjectItemCaseSensitive(obj, names[i])) return false;
    return seen <= n;
}
static const char *member_str(const cJSON *o, const char *k) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool int_member(const cJSON *o, const char *k, uint32_t lo, uint32_t hi, uint32_t *out) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    if (!cJSON_IsNumber(v) || v->valuedouble < lo || v->valuedouble > hi) return false;
    *out = (uint32_t)v->valuedouble;
    return (double)*out == v->valuedouble;
}
static bool task_token(const char *s) {
    if (!s) return false;
    size_t n = strlen(s);
    if (!n || n > 64) return false;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        bool alnum = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (!alnum && (i == 0 || !(c == '.' || c == '_' || c == ':' || c == '-'))) return false;
    }
    return true;
}
static bool failure_kind(const char *k) {
    return k && (!strcmp(k, "denied") || !strcmp(k, "unavailable") || !strcmp(k, "expired") ||
                 !strcmp(k, "failed") || !strcmp(k, "unknown_outcome"));
}
static bool failure_object(const cJSON *f) {
    static const char *const names[] = {"kind", "message"};
    const char *msg = member_str(f, "message");
    return exact_members(f, names, 2, 0) && failure_kind(member_str(f, "kind")) && msg &&
           pdsh_task_valid_output(msg, 256);
}
static bool outcome_object(const cJSON *o, bool completed) {
    if (completed) {
        static const char *const names[] = {"output", "truncated"};
        const char *out = member_str(o, "output");
        return exact_members(o, names, 2, 0) && out && pdsh_task_valid_output(out, 1024) &&
               cJSON_IsBool(cJSON_GetObjectItemCaseSensitive(o, "truncated"));
    }
    static const char *const names[] = {"failure"};
    return exact_members(o, names, 1, 0) && failure_object(cJSON_GetObjectItemCaseSensitive(o, "failure"));
}

static bool decode_fields(cJSON *root, pdsh_msg_dir_t dir, pdsh_msg_t *m) {
    const char *t = member_str(root, "t");
    uint32_t v = 0;
    if (!t || !int_member(root, "v", 1, 1, &v)) return false;
    m->device = member_str(root, "device");
    m->phone = member_str(root, "phone");
    m->eid = member_str(root, "eid");
    m->cc = member_str(root, "cc");
    m->sc = member_str(root, "sc");
    m->id = member_str(root, "id");
    m->idem = member_str(root, "idem");
    if (!strcmp(t, "err")) {
        static const char *const names[] = {"v", "t", "re", "code"};
        m->type = PDSH_MSG_ERR;
        m->code = error_code(member_str(root, "code"));
        if (!exact_members(root, names, 4, 0) || m->code == PDSH_ERR_NONE) return false;
        return int_member(root, "re", 0, dir == PDSH_DIR_C2S ? 0 : 65535, &m->re);
    }
    if (dir == PDSH_DIR_C2S) {
        if (!int_member(root, "seq", 1, 65535, &m->seq)) return false;
        bool sc_ok = pdsh_lower_hex(m->sc, PDSH_SS_CHALLENGE_HEX);
        bool task_ok = task_token(m->id) && task_token(m->idem);
        if (!strcmp(t, "ready_req")) {
            static const char *const names[] = {"v", "t", "seq", "device", "phone", "eid", "cc"};
            m->type = PDSH_MSG_READY_REQ;
            return exact_members(root, names, 7, 0) && pdsh_device_id_valid(m->device) &&
                   pdsh_phone_id_valid(m->phone) && pdsh_lower_hex(m->eid, PDSH_SS_EID_HEX) &&
                   pdsh_lower_hex(m->cc, PDSH_SS_CHALLENGE_HEX);
        }
        if (!strcmp(t, "next")) {
            static const char *const names[] = {"v", "t", "seq", "sc"};
            m->type = PDSH_MSG_NEXT;
            return exact_members(root, names, 4, 0) && sc_ok;
        }
        if (!strcmp(t, "accept") || !strcmp(t, "status")) {
            static const char *const names[] = {"v", "t", "seq", "sc", "id", "idem"};
            m->type = t[0] == 'a' ? PDSH_MSG_ACCEPT : PDSH_MSG_STATUS;
            return exact_members(root, names, 6, 0) && sc_ok && task_ok;
        }
        if (!strcmp(t, "complete")) {
            static const char *const names[] = {"v", "t", "seq", "sc", "id", "idem", "output", "truncated"};
            m->type = PDSH_MSG_COMPLETE;
            m->output = cJSON_GetObjectItemCaseSensitive(root, "output");
            m->truncated = cJSON_GetObjectItemCaseSensitive(root, "truncated");
            return exact_members(root, names, 8, 0) && sc_ok && task_ok && cJSON_IsString(m->output) &&
                   pdsh_task_valid_output(m->output->valuestring, 1024) && cJSON_IsBool(m->truncated);
        }
        if (!strcmp(t, "fail")) {
            static const char *const names[] = {"v", "t", "seq", "sc", "id", "idem", "failure"};
            m->type = PDSH_MSG_FAIL;
            m->failure = cJSON_GetObjectItemCaseSensitive(root, "failure");
            return exact_members(root, names, 7, 0) && sc_ok && task_ok && failure_object(m->failure);
        }
        return false;
    }
    if (!int_member(root, "re", 1, 65535, &m->re)) return false;
    const cJSON *phase = cJSON_GetObjectItemCaseSensitive(root, "phase");
    const char *ph = cJSON_IsString(phase) ? phase->valuestring : NULL;
    if (!strcmp(t, "ready_ack")) {
        static const char *const names[] = {"v", "t", "re", "device", "phone", "eid", "cc", "sc"};
        m->type = PDSH_MSG_READY_ACK;
        return m->re == 1 && exact_members(root, names, 8, 0) && pdsh_device_id_valid(m->device) &&
               pdsh_phone_id_valid(m->phone) && pdsh_lower_hex(m->eid, PDSH_SS_EID_HEX) &&
               pdsh_lower_hex(m->cc, PDSH_SS_CHALLENGE_HEX) && pdsh_lower_hex(m->sc, PDSH_SS_CHALLENGE_HEX);
    }
    if (!strcmp(t, "next_r")) {
        static const char *const names[] = {"v", "t", "re", "task", "phase"};
        const cJSON *task = cJSON_GetObjectItemCaseSensitive(root, "task");
        m->type = PDSH_MSG_NEXT_R;
        if (!exact_members(root, names, 5, 0)) return false;
        if (cJSON_IsNull(task)) return cJSON_IsNull(phase);
        return cJSON_IsObject(task) && ph && (!strcmp(ph, "queued") || !strcmp(ph, "accepted")) &&
               pdsh_task_validate(task);
    }
    if (!strcmp(t, "r")) {
        static const char *const names[] = {"v", "t", "re", "result", "phase"};
        const char *result = member_str(root, "result");
        m->type = PDSH_MSG_R;
        return exact_members(root, names, 5, 0) && result &&
               (!strcmp(result, "applied") || !strcmp(result, "duplicate")) && ph &&
               (!strcmp(ph, "accepted") || !strcmp(ph, "completed") || !strcmp(ph, "failed"));
    }
    if (!strcmp(t, "status_r")) {
        static const char *const names[] = {"v", "t", "re", "phase", "mine", "outcome"};
        const cJSON *mine = cJSON_GetObjectItemCaseSensitive(root, "mine");
        const cJSON *outcome = cJSON_GetObjectItemCaseSensitive(root, "outcome");
        m->type = PDSH_MSG_STATUS_R;
        if (!exact_members(root, names, 6, 1) || !ph || !cJSON_IsBool(mine)) return false;
        bool terminal = !strcmp(ph, "completed") || !strcmp(ph, "failed");
        bool early = !strcmp(ph, "unknown") || !strcmp(ph, "queued");
        if (!terminal && !early && strcmp(ph, "accepted")) return false;
        if (early && cJSON_IsTrue(mine)) return false;
        if ((outcome != NULL) != (terminal && cJSON_IsTrue(mine))) return false;
        return !outcome || outcome_object(outcome, !strcmp(ph, "completed"));
    }
    return false;
}

bool pdsh_msg_decode(const uint8_t *payload, size_t n, pdsh_msg_dir_t dir, pdsh_msg_t *out) {
    memset(out, 0, sizeof(*out));
    if (!payload || n == 0 || n > PDSH_SS_FRAME_MAX || !pdsh_json_strict(payload, n)) return false;
    char *text = malloc(n + 1);
    if (!text) return false;
    memcpy(text, payload, n);
    text[n] = 0;
    cJSON *root = cJSON_ParseWithLengthOpts(text, n + 1, NULL, true);
    free(text);
    if (!root || !cJSON_IsObject(root) || !pdsh_task_unique_keys(root) || !decode_fields(root, dir, out)) {
        cJSON_Delete(root);
        memset(out, 0, sizeof(*out));
        return false;
    }
    out->root = root;
    return true;
}
void pdsh_msg_free(pdsh_msg_t *msg) {
    cJSON_Delete(msg->root);
    memset(msg, 0, sizeof(*msg));
}

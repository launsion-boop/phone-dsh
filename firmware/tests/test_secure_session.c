// SPDX-License-Identifier: MIT
/* secure-session: drives the real firmware identifiers, certificate verifier
 * and builder, frame decoder, message codec, session state machine and the
 * TLS 1.3 server profile (pdsh_secure_*.c, pdsh_enroll.c, pdsh_task_store.c)
 * with the shared golden files, then runs an in-process TLS loopback between
 * the real server configuration and an independent mbedTLS client built from
 * the same profile, including the §6.1/§6.2 negative cases. */
#include "mbedtls/debug.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "pdsh_enroll.h"
#include "pdsh_identity.h"
#include "pdsh_secure_cert.h"
#include "pdsh_secure_msg.h"
#include "pdsh_secure_session.h"
#include "pdsh_task_store.h"
#include "psa/crypto.h"
#include "test_secure_support.h"
#include <stdlib.h>
#include <string.h>

static const char *D = "9f884378e0c09834f2d27bb467eb005ee6cba0e2b66e0220b1b702e31f74473c";

/* ---------------- identifiers ---------------- */
static int identifiers(const char *path, int *not_applicable) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0;
    char *line;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring, *kind = cJSON_GetObjectItem(row, "kind")->valuestring;
        bool valid = cJSON_IsTrue(cJSON_GetObjectItem(row, "valid"));
        if (!strcmp(kind, "public_key")) {
            uint8_t point[65];
            pdsh_key_status_t st = pdsh_pubkey_check_hex(cJSON_GetObjectItem(row, "hex")->valuestring, point);
            CHECK((st == PDSH_KEY_OK) == valid, "%s: %s", name, pdsh_key_status_name(st));
            if (valid) {
                char fp[65], id[80];
                CHECK(pdsh_fingerprint(point, fp) && !strcmp(fp, cJSON_GetObjectItem(row, "fingerprint")->valuestring), "%s fp", name);
                snprintf(id, sizeof(id), "ble:%s", fp);
                CHECK(!strcmp(id, cJSON_GetObjectItem(row, "device_id")->valuestring) && pdsh_device_id_valid(id), "%s id", name);
                snprintf(id, sizeof(id), "phone:%s", fp);
                CHECK(!strcmp(id, cJSON_GetObjectItem(row, "phone_id")->valuestring) && pdsh_phone_id_valid(id), "%s pid", name);
            } else
                CHECK(!strcmp(pdsh_key_status_name(st), cJSON_GetObjectItem(row, "reason")->valuestring), "%s: reason %s",
                      name, pdsh_key_status_name(st));
        } else if (!strcmp(kind, "identifier")) {
            const char *text = cJSON_GetObjectItem(row, "text")->valuestring;
            bool got = !strcmp(cJSON_GetObjectItem(row, "role")->valuestring, "device") ? pdsh_device_id_valid(text)
                                                                                          : pdsh_phone_id_valid(text);
            CHECK(got == valid, "%s", name);
        } else if (!strcmp(kind, "eid")) {
            CHECK(pdsh_lower_hex(cJSON_GetObjectItem(row, "text")->valuestring, 32) == valid, "%s", name);
        } else {
            (*not_applicable)++; /* board/phone token input is a phone-side rule (§3.4) */
        }
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    return rows;
}

/* ---------------- certificates ---------------- */
static int certificates(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0;
    char *line;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        const cJSON *chain = cJSON_GetObjectItem(row, "chain_hex");
        uint8_t ders[4][2048];
        const uint8_t *der[4];
        size_t len[4], count = 0;
        const cJSON *c;
        cJSON_ArrayForEach(c, chain) {
            len[count] = hex_bytes(c->valuestring, ders[count], sizeof(ders[0]));
            der[count] = ders[count];
            count++;
        }
        pdsh_cert_status_t st = pdsh_cert_verify_chain(der, len, count, cJSON_GetObjectItem(row, "pin")->valuestring);
        bool accept = cJSON_IsTrue(cJSON_GetObjectItem(row, "accept"));
        CHECK((st == PDSH_CERT_OK) == accept, "%s: %s", name, pdsh_cert_status_name(st));
        if (!accept)
            CHECK(!strcmp(pdsh_cert_status_name(st), cJSON_GetObjectItem(row, "reason")->valuestring), "%s: reason %s", name,
                  pdsh_cert_status_name(st));
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    return rows;
}

/* ---------------- frames ---------------- */
static int frames(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0;
    char *line;
    static pdsh_frame_decoder_t dec;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        const cJSON *err = cJSON_GetObjectItem(row, "error"), *want = cJSON_GetObjectItem(row, "payloads_hex"), *c;
        pdsh_frame_reset(&dec);
        int got = 0;
        bool limit = false;
        cJSON_ArrayForEach(c, cJSON_GetObjectItem(row, "chunks_hex")) {
            static uint8_t chunk[8192];
            size_t n = hex_bytes(c->valuestring, chunk, sizeof(chunk));
            const uint8_t *p = chunk;
            while (!limit) {
                const uint8_t *payload;
                size_t plen;
                pdsh_frame_result_t r = pdsh_frame_next(&dec, &p, &n, &payload, &plen);
                if (r == PDSH_FRAME_LIMIT) limit = true;
                else if (r == PDSH_FRAME_PAYLOAD) {
                    static uint8_t expect[8192];
                    const cJSON *w = cJSON_GetArrayItem(want, got);
                    CHECK(w, "%s: extra payload", name);
                    size_t m = hex_bytes(w->valuestring, expect, sizeof(expect));
                    CHECK(m == plen && !memcmp(expect, payload, m), "%s: payload %d", name, got);
                    got++;
                } else break;
            }
        }
        CHECK(got == cJSON_GetArraySize(want), "%s: payload count %d", name, got);
        bool eof = cJSON_IsTrue(cJSON_GetObjectItem(row, "eof"));
        const char *error = cJSON_IsNull(err) ? NULL : err->valuestring;
        if (error && !strcmp(error, "limit")) CHECK(limit, "%s: limit", name);
        else if (error && !strcmp(error, "truncated")) CHECK(eof && pdsh_frame_pending(&dec) && !limit, "%s: truncated", name);
        else CHECK(!limit && (!eof || !pdsh_frame_pending(&dec)), "%s: clean end", name);
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    return rows;
}

/* ---------------- messages ---------------- */
static const char *type_name(pdsh_msg_type_t t) {
    static const char *const n[] = {"ready_req", "next", "accept", "complete", "fail", "status",
                                    "err", "ready_ack", "next_r", "r", "status_r"};
    return n[t];
}
static int messages(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0;
    char *line;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        static uint8_t payload[8192];
        size_t n = hex_bytes(cJSON_GetObjectItem(row, "payload_hex")->valuestring, payload, sizeof(payload));
        pdsh_msg_dir_t dir = !strcmp(cJSON_GetObjectItem(row, "dir")->valuestring, "c2s") ? PDSH_DIR_C2S : PDSH_DIR_S2C;
        pdsh_msg_t m;
        bool ok = pdsh_msg_decode(payload, n, dir, &m);
        CHECK(ok == cJSON_IsTrue(cJSON_GetObjectItem(row, "valid")), "%s: decode %d", name, ok);
        if (ok) CHECK(!strcmp(type_name(m.type), cJSON_GetObjectItem(row, "t")->valuestring), "%s: type", name);
        pdsh_msg_free(&m);
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    return rows;
}

/* ---------------- device sequences ---------------- */
static uint64_t clock_ms;
static char sc_fixture[65], enroll_out[4][512];
static int enroll_outputs;
static uint8_t emitted[16][8192];
static size_t emitted_len[16];
static int emitted_count;
static uint64_t now_ms(void) { return clock_ms; }
static void enroll_line(const char *line) {
    if (enroll_outputs < 4) snprintf(enroll_out[enroll_outputs++], sizeof(enroll_out[0]), "%s", line);
}
static void no_random(uint8_t *out, size_t n) { memset(out, 0x11, n); }
static pdsh_identity_status_t fixture_probe(char fp[65]) {
    snprintf(fp, 65, "%s", D);
    return PDSH_IDENTITY_OK;
}
static pdsh_enroll_ops_t fixture_ops = {now_ms, no_random, true, enroll_line, fixture_probe, NULL, NULL};
static void sc_random(uint8_t *out, size_t n) { CHECK(n == 32 && pdsh_hex_decode(sc_fixture, out, 32), "sc"); }
static void collect(void *ctx, const uint8_t *frame, size_t n) {
    (void)ctx;
    CHECK(emitted_count < 16 && n <= sizeof(emitted[0]), "emit");
    memcpy(emitted[emitted_count], frame, n);
    emitted_len[emitted_count++] = n;
}
static void button_press(void) {
    bool levels[] = {false, false, true, true, false, false};
    for (int i = 0; i < 6; i++) {
        clock_ms += 60;
        pdsh_enroll_button(levels[i]);
    }
}
static nvs_handle_t open_ns(const char *name) {
    nvs_handle_t h;
    CHECK(nvs_open(name, NVS_READWRITE, &h) == ESP_OK, "open");
    return h;
}
static void put_json(const char *ns, const char *key, const cJSON *value) {
    char *text = cJSON_PrintUnformatted(value);
    fake_nvs_put(ns, key, text, strlen(text) + 1);
    free(text);
}
static int sequences(const char *path, int *steps_out) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0, steps = 0;
    char *line;
    static pdsh_ss_app_t app;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        if (strcmp(cJSON_GetObjectItem(row, "side")->valuestring, "device")) {
            cJSON_Delete(row);
            free(line);
            continue;
        }
        const cJSON *given = cJSON_GetObjectItem(row, "given"), *rec = cJSON_GetObjectItem(given, "record");
        fake_nvs_reset();
        clock_ms = 1000000;
        cJSON *stored = cJSON_CreateObject();
        cJSON_AddStringToObject(stored, "state", cJSON_GetObjectItem(rec, "state")->valuestring);
        cJSON *record = cJSON_Parse("{\"v\":1,\"side\":\"board\"}");
        char text[200];
        cJSON_AddStringToObject(record, "state", cJSON_GetObjectItem(rec, "state")->valuestring);
        snprintf(text, sizeof(text), "ble:%s", cJSON_GetObjectItem(rec, "device")->valuestring);
        cJSON_AddStringToObject(record, "device", text);
        snprintf(text, sizeof(text), "phone:%s", cJSON_GetObjectItem(rec, "phone")->valuestring);
        cJSON_AddStringToObject(record, "phone", text);
        cJSON_AddStringToObject(record, "eid", cJSON_GetObjectItem(rec, "eid")->valuestring);
        cJSON_AddNumberToObject(record, "rev", cJSON_GetObjectItem(rec, "rev")->valuedouble);
        put_json("pdsh_enr", "rec_v1", record);
        cJSON_Delete(record);
        cJSON_Delete(stored);
        cJSON *doc = cJSON_CreateObject();
        cJSON_AddNumberToObject(doc, "v", 2);
        cJSON_AddItemToObject(doc, "slots", cJSON_Duplicate(cJSON_GetObjectItem(given, "store"), true));
        put_json("pdsh_tools", "tasks_v2", doc);
        cJSON_Delete(doc);
        pdsh_enroll_init(&fixture_ops, open_ns("pdsh_enr"));
        CHECK(pdsh_task_store_init(open_ns("pdsh_tools")), "%s: store", name);
        snprintf(sc_fixture, sizeof(sc_fixture), "%s", cJSON_GetObjectItem(given, "sc")->valuestring);
        emitted_count = 0;
        bool started = pdsh_ss_app_start(&app, cJSON_GetObjectItem(given, "peer_phone")->valuestring, clock_ms,
                                         &pdsh_ss_timers_v1, sc_random, collect, NULL);
        bool accept = !strcmp(cJSON_GetObjectItem(row, "handshake")->valuestring, "accept");
        CHECK(started == accept, "%s: handshake gate %d", name, started);
        int i = 0;
        const cJSON *step;
        cJSON_ArrayForEach(step, cJSON_GetObjectItem(row, "steps")) {
            const cJSON *recv = cJSON_GetObjectItem(step, "recv"), *event = cJSON_GetObjectItem(step, "event");
            const cJSON *expect = cJSON_GetObjectItem(step, "expect");
            bool was_open = app.state != PDSH_SS_APP_CLOSED;
            emitted_count = 0;
            clock_ms += 100;
            if (recv) {
                char *json = cJSON_PrintUnformatted(recv);
                size_t n = strlen(json);
                uint8_t *frame = malloc(n + 2);
                CHECK(pdsh_frame_encode((uint8_t *)json, n, frame), "frame");
                /* Split the frame to exercise reassembly across TLS records. */
                size_t half = (n + 2) / 2;
                pdsh_ss_app_input(&app, frame, half, clock_ms);
                pdsh_ss_app_input(&app, frame + half, n + 2 - half, clock_ms);
                free(frame);
                free(json);
            } else {
                const char *e = event->valuestring;
                if (!strcmp(e, "revoke")) {
                    char cmd[300];
                    snprintf(cmd, sizeof(cmd), "pdsh-enroll revoke eid=%s device=%s phone=%s\n",
                             cJSON_GetObjectItem(rec, "eid")->valuestring, D, cJSON_GetObjectItem(rec, "phone")->valuestring);
                    enroll_outputs = 0;
                    pdsh_enroll_feed((const uint8_t *)cmd, strlen(cmd));
                    button_press();
                    CHECK(enroll_outputs == 2 && strstr(enroll_out[1], "pdsh-enroll-r revoked"), "%s: revoke", name);
                    pdsh_ss_app_tick(&app, clock_ms);
                } else if (!strcmp(e, "ready_timeout")) {
                    clock_ms += pdsh_ss_timers_v1.ready_ms;
                    pdsh_ss_app_tick(&app, clock_ms);
                } else if (!strcmp(e, "idle_timeout")) {
                    clock_ms += pdsh_ss_timers_v1.idle_ms;
                    pdsh_ss_app_tick(&app, clock_ms);
                } else if (!strcmp(e, "fail_next_write")) fake_nvs_fail_next_commit();
                else CHECK(false, "%s: event %s", name, e);
            }
            const cJSON *send = cJSON_GetObjectItem(expect, "send");
            if (cJSON_IsNull(send)) CHECK(emitted_count == 0, "%s step %d: unexpected output", name, i);
            else {
                CHECK(emitted_count == 1, "%s step %d: %d outputs", name, i, emitted_count);
                size_t n = emitted[0][0] | (size_t)emitted[0][1] << 8;
                CHECK(n + 2 == emitted_len[0], "%s step %d: frame length", name, i);
                pdsh_msg_t m;
                CHECK(pdsh_msg_decode(emitted[0] + 2, n, PDSH_DIR_S2C, &m), "%s step %d: own output decodes", name, i);
                pdsh_msg_free(&m);
                cJSON *got = cJSON_ParseWithLength((const char *)emitted[0] + 2, n);
                char *g = cJSON_PrintUnformatted(got);
                CHECK(cJSON_Compare(got, send, true), "%s step %d: got %s", name, i, g);
                free(g);
                cJSON_Delete(got);
            }
            bool closes = cJSON_IsTrue(cJSON_GetObjectItem(expect, "close"));
            if (closes) CHECK(was_open && app.state == PDSH_SS_APP_CLOSED, "%s step %d: close", name, i);
            else CHECK(!was_open || app.state != PDSH_SS_APP_CLOSED, "%s step %d: stayed open", name, i);
            i++;
            steps++;
        }
        /* The store tells the truth after a reboot. */
        CHECK(pdsh_task_store_init(open_ns("pdsh_tools")), "%s: reload", name);
        cJSON *view = pdsh_task_store_view();
        CHECK(cJSON_Compare(view, cJSON_GetObjectItem(row, "final_store"), true), "%s: final store", name);
        cJSON_Delete(view);
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    *steps_out = steps;
    return rows;
}

/* ---------------- TLS loopback ---------------- */
typedef struct {
    uint8_t buf[65536];
    size_t len;
} pipe_t;
static pipe_t c2s, s2c;
static int pipe_send(void *ctx, const unsigned char *buf, size_t len) {
    (void)ctx;
    pipe_t *p = &c2s;
    CHECK(p->len + len <= sizeof(p->buf), "pipe");
    memcpy(p->buf + p->len, buf, len);
    p->len += len;
    return (int)len;
}
static int pipe_recv(void *ctx, unsigned char *buf, size_t len) {
    (void)ctx;
    pipe_t *p = &s2c;
    if (!p->len) return MBEDTLS_ERR_SSL_WANT_READ;
    size_t n = len < p->len ? len : p->len;
    memcpy(buf, p->buf, n);
    memmove(p->buf, p->buf + n, p->len - n);
    p->len -= n;
    return (int)n;
}
static void real_random(uint8_t *out, size_t n) { CHECK(psa_generate_random(out, n) == PSA_SUCCESS, "rng"); }
static psa_key_id_t new_key(void) {
    psa_key_attributes_t a = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&a, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&a, 256);
    psa_set_key_usage_flags(&a, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_SIGN_MESSAGE);
    psa_set_key_algorithm(&a, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_key_id_t k;
    CHECK(psa_generate_key(&a, &k) == PSA_SUCCESS, "keygen");
    return k;
}
static void key_fp(psa_key_id_t k, char fp[65]) {
    uint8_t point[65];
    size_t n;
    CHECK(psa_export_public_key(k, point, 65, &n) == PSA_SUCCESS && n == 65 && pdsh_fingerprint(point, fp), "fp");
}
/* Test certificate variants for the negative cases (not the firmware builder). */
typedef enum { VARIANT_PROFILE, VARIANT_CA, VARIANT_EKU, VARIANT_CRITICAL } variant_t;
static size_t variant_cert(psa_key_id_t k, variant_t v, uint8_t *out, size_t cap) {
    if (v == VARIANT_PROFILE) {
        size_t len;
        CHECK(pdsh_cert_build(k, false, out, cap, &len), "build");
        return len;
    }
    mbedtls_pk_context pk;
    mbedtls_x509write_cert w;
    mbedtls_pk_init(&pk);
    mbedtls_x509write_crt_init(&w);
    CHECK(mbedtls_pk_wrap_psa(&pk, k) == 0, "wrap");
    mbedtls_x509write_crt_set_md_alg(&w, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&w, &pk);
    mbedtls_x509write_crt_set_issuer_key(&w, &pk);
    unsigned char serial[] = {2};
    mbedtls_x509write_crt_set_serial_raw(&w, serial, 1);
    mbedtls_x509write_crt_set_validity(&w, "20260101000000", "99991231235959");
    mbedtls_x509write_crt_set_subject_name(&w, "CN=pdsh-ble-phone");
    mbedtls_x509write_crt_set_issuer_name(&w, "CN=pdsh-ble-phone");
    static const uint8_t bc_ca[] = {0x30, 0x03, 0x01, 0x01, 0xff}, bc[] = {0x30, 0x00}, ku[] = {0x03, 0x02, 0x07, 0x80};
    static const uint8_t eku[] = {0x30, 0x0a, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02};
    static const uint8_t null_value[] = {0x05, 0x00};
    mbedtls_x509write_crt_set_extension(&w, "\x55\x1d\x13", 3, 1, v == VARIANT_CA ? bc_ca : bc, v == VARIANT_CA ? 5 : 2);
    mbedtls_x509write_crt_set_extension(&w, "\x55\x1d\x0f", 3, 1, ku, sizeof(ku));
    if (v == VARIANT_EKU) mbedtls_x509write_crt_set_extension(&w, "\x55\x1d\x25", 3, 0, eku, sizeof(eku));
    if (v == VARIANT_CRITICAL)
        mbedtls_x509write_crt_set_extension(&w, "\x2b\x06\x01\x04\x01\x82\x37\x01", 8, 1, null_value, 2);
    int n = mbedtls_x509write_crt_der(&w, out, cap);
    CHECK(n > 0, "der");
    memmove(out, out + cap - (size_t)n, (size_t)n);
    mbedtls_x509write_crt_free(&w);
    mbedtls_pk_free(&pk);
    return (size_t)n;
}

typedef struct {
    int max_version;
    int suite;
    uint16_t groups[3];
    const char *alpn[3];
    bool no_alpn, psk, no_cert, wrong_private_key, revoked;
    variant_t variant;
    bool enrolled_phone; /* false: a phone key that is not enrolled */
} client_case_t;

static char device_fp[65];
static uint8_t device_cert[1024];
static size_t device_cert_len;
static int client_verify(void *ctx, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
    (void)ctx;
    *flags &= ~(uint32_t)(MBEDTLS_X509_BADCERT_NOT_TRUSTED | MBEDTLS_X509_BADCERT_EXPIRED | MBEDTLS_X509_BADCERT_FUTURE);
    if (depth) return 0;
    const uint8_t *der[4];
    size_t len[4], count = 0;
    for (const mbedtls_x509_crt *p = crt; p && count < 4; p = p->next, count++) der[count] = p->raw.p, len[count] = p->raw.len;
    if (pdsh_cert_verify_chain(der, len, count, device_fp) != PDSH_CERT_OK) *flags |= MBEDTLS_X509_BADCERT_CN_MISMATCH;
    return 0;
}

static void write_frame(mbedtls_ssl_context *cl, const char *json) {
    uint8_t frame[4200];
    size_t n = strlen(json);
    CHECK(pdsh_frame_encode((const uint8_t *)json, n, frame), "frame");
    CHECK(mbedtls_ssl_write(cl, frame, n + 2) == (int)(n + 2), "client write");
}
/* Pumps bytes until the client produced a result or nothing moves. */
static int pump(pdsh_ss_conn_t *srv, mbedtls_ssl_context *cl, bool handshake, uint8_t *app, size_t cap, size_t *got) {
    int r = MBEDTLS_ERR_SSL_WANT_READ;
    for (int i = 0; i < 400; i++) {
        if (c2s.len) {
            CHECK(pdsh_ss_conn_rx(srv, c2s.buf, c2s.len), "server rx overflow");
            c2s.len = 0;
        }
        clock_ms += 5;
        pdsh_ss_conn_poll(srv, clock_ms);
        s2c.len += pdsh_ss_conn_tx(srv, s2c.buf + s2c.len, sizeof(s2c.buf) - s2c.len);
        if (handshake) {
            r = mbedtls_ssl_handshake(cl);
            if (r == 0) return 0;
        } else {
            r = mbedtls_ssl_read(cl, app + *got, cap - *got);
            if (r > 0) {
                *got += (size_t)r;
                if (*got >= 2 && *got >= 2 + (size_t)(app[0] | app[1] << 8)) return 0;
                continue;
            }
        }
        if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) return r;
        if (!c2s.len && !s2c.len && pdsh_ss_conn_poll(srv, clock_ms) == PDSH_SS_CONN_CLOSED && i > 2) return r;
    }
    return r;
}
static cJSON *exchange(pdsh_ss_conn_t *srv, mbedtls_ssl_context *cl, const char *json) {
    write_frame(cl, json);
    static uint8_t app[8192];
    size_t got = 0;
    int r = pump(srv, cl, false, app, sizeof(app), &got);
    if (r) return NULL;
    size_t n = app[0] | (size_t)app[1] << 8;
    return cJSON_ParseWithLength((const char *)app + 2, n);
}

static void tls_debug(void *ctx, int level, const char *file, int line, const char *msg) {
    (void)level;
    fprintf(stderr, "%s %s:%d %s", (const char *)ctx, file, line, msg);
}
static int accept_any_extension(void *ctx, mbedtls_x509_crt const *crt, mbedtls_x509_buf const *oid, int critical,
                                const unsigned char *p, const unsigned char *end) {
    (void)ctx; (void)crt; (void)oid; (void)critical; (void)p; (void)end;
    return 0;
}
static const uint16_t sig_algs[] = {MBEDTLS_TLS1_3_SIG_ECDSA_SECP256R1_SHA256, MBEDTLS_TLS1_3_SIG_NONE};
static psa_key_id_t phone_key, other_key;
static char phone_fp[65];

/* Runs one connection; returns true when the handshake succeeded on both
 * ends. On success performs the readiness and a task round trip. */
static int client_alert, client_error;
static bool run_case(const pdsh_ss_server_cfg_t *cfg, const client_case_t *cc, const char *label, bool round_trip,
                     const char **server_reason, int *server_alert) {
    client_alert = -1;
    c2s.len = s2c.len = 0;
    /* Board state: committed (or revoked) record for the enrolled phone. */
    char rec[512];
    snprintf(rec, sizeof(rec),
             "{\"v\":1,\"side\":\"board\",\"state\":\"%s\",\"device\":\"ble:%s\",\"phone\":\"phone:%s\",\"eid\":\"%s\",\"rev\":1}",
             cc->revoked ? "revoked" : "committed", device_fp, phone_fp, "6f1c0a8e2b9d4c3fa1e0b7d6c5f4e3d2");
    fake_nvs_put("pdsh_enr", "rec_v1", rec, strlen(rec) + 1);
    static pdsh_enroll_ops_t ops = {now_ms, real_random, true, enroll_line, pdsh_identity_probe, pdsh_identity_reset, NULL};
    pdsh_enroll_init(&ops, open_ns("pdsh_enr"));
    const char *slots = "{\"v\":2,\"slots\":[{\"task\":{\"id\":\"task-1\",\"idempotency_key\":\"goal-1\",\"requester\":\"sensor\","
                        "\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}},\"phase\":\"queued\"}]}";
    fake_nvs_put("pdsh_tools", "tasks_v2", slots, strlen(slots) + 1);
    CHECK(pdsh_task_store_init(open_ns("pdsh_tools")), "store");

    pdsh_ss_conn_t *srv = pdsh_ss_conn_new(cfg, clock_ms);
    CHECK(srv, "server");
    mbedtls_ssl_config conf;
    mbedtls_ssl_context cl;
    mbedtls_x509_crt own, anchor;
    mbedtls_pk_context pk;
    mbedtls_ssl_config_init(&conf);
    mbedtls_ssl_init(&cl);
    mbedtls_x509_crt_init(&own);
    mbedtls_x509_crt_init(&anchor);
    mbedtls_pk_init(&pk);
    CHECK(mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) == 0, "conf");
    mbedtls_ssl_conf_min_tls_version(&conf, cc->max_version == 2 ? MBEDTLS_SSL_VERSION_TLS1_2 : MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_max_tls_version(&conf, cc->max_version == 2 ? MBEDTLS_SSL_VERSION_TLS1_2 : MBEDTLS_SSL_VERSION_TLS1_3);
    int suites[] = {cc->suite ? cc->suite : MBEDTLS_TLS1_3_AES_128_GCM_SHA256, 0};
    mbedtls_ssl_conf_ciphersuites(&conf, suites);
    uint16_t groups[3] = {MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1, 0, 0};
    if (cc->groups[0]) memcpy(groups, cc->groups, sizeof(groups));
    mbedtls_ssl_conf_groups(&conf, groups);
    mbedtls_ssl_conf_sig_algs(&conf, sig_algs);
    mbedtls_ssl_conf_session_tickets(&conf, MBEDTLS_SSL_SESSION_TICKETS_DISABLED);
    if (cc->psk) {
        static const unsigned char psk[32] = {1};
        CHECK(mbedtls_ssl_conf_psk(&conf, psk, sizeof(psk), (const unsigned char *)"id", 2) == 0, "psk");
        mbedtls_ssl_conf_tls13_key_exchange_modes(&conf, MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_ALL);
    } else
        mbedtls_ssl_conf_tls13_key_exchange_modes(&conf, MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL);
    static const char *ok_alpn[] = {PDSH_SS_ALPN, NULL};
    if (!cc->no_alpn) CHECK(mbedtls_ssl_conf_alpn_protocols(&conf, cc->alpn[0] ? (const char **)cc->alpn : ok_alpn) == 0, "alpn");
    CHECK(mbedtls_x509_crt_parse_der(&anchor, device_cert, device_cert_len) == 0, "anchor");
    mbedtls_ssl_conf_ca_chain(&conf, &anchor, NULL);
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_verify(&conf, client_verify, NULL);
    if (!cc->no_cert) {
        uint8_t der[1200];
        psa_key_id_t cert_key = cc->enrolled_phone ? phone_key : other_key;
        size_t n = variant_cert(cert_key, cc->variant, der, sizeof(der));
        /* The client loads its own (possibly non-conforming) certificate
         * without judging it; the server must reject it. */
        CHECK(mbedtls_x509_crt_parse_der_with_ext_cb(&own, der, n, 1, accept_any_extension, NULL) == 0, "own cert");
        CHECK(mbedtls_pk_wrap_psa(&pk, cc->wrong_private_key ? other_key : cert_key) == 0, "client key");
        CHECK(mbedtls_ssl_conf_own_cert(&conf, &own, &pk) == 0, "own");
    }
    if (getenv("PDSH_TLS_DEBUG")) {
        mbedtls_debug_set_threshold(atoi(getenv("PDSH_TLS_DEBUG")));
        mbedtls_ssl_conf_dbg(&conf, tls_debug, (void *)"client");
    }
    CHECK(mbedtls_ssl_setup(&cl, &conf) == 0, "setup");
    /* No server_name: verification relies on the pin, not on a host name. */
    CHECK(mbedtls_ssl_set_hostname(&cl, NULL) == 0, "hostname");
    mbedtls_ssl_set_bio(&cl, &c2s, pipe_send, pipe_recv, NULL);

    int r = pump(srv, &cl, true, NULL, 0, NULL);
    /* TLS 1.3: the client finishes before the server has judged the client
     * flight; let the server process it. */
    pdsh_ss_conn_state_t st = PDSH_SS_CONN_HANDSHAKE;
    for (int i = 0; i < 50 && st == PDSH_SS_CONN_HANDSHAKE; i++) {
        if (c2s.len) {
            CHECK(pdsh_ss_conn_rx(srv, c2s.buf, c2s.len), "server rx overflow");
            c2s.len = 0;
        }
        clock_ms += 5;
        st = pdsh_ss_conn_poll(srv, clock_ms);
        s2c.len += pdsh_ss_conn_tx(srv, s2c.buf + s2c.len, sizeof(s2c.buf) - s2c.len);
    }
    bool ok = r == 0 && st == PDSH_SS_CONN_OPEN;
    if (getenv("PDSH_TLS_DEBUG")) fprintf(stderr, "[%s] client=-0x%04x server=%s alert=%d\n", label, (unsigned)-r, pdsh_ss_conn_reason(srv), pdsh_ss_conn_alert(srv));
    if (ok) {
        CHECK(!strcmp(mbedtls_ssl_get_alpn_protocol(&cl), PDSH_SS_ALPN), "%s: alpn", label);
    }
    if (ok && round_trip) {
        char json[600];
        snprintf(json, sizeof(json),
                 "{\"v\":1,\"t\":\"ready_req\",\"seq\":1,\"device\":\"ble:%s\",\"phone\":\"phone:%s\",\"eid\":"
                 "\"6f1c0a8e2b9d4c3fa1e0b7d6c5f4e3d2\",\"cc\":\"%s\"}",
                 device_fp, phone_fp, "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1");
        cJSON *ack = exchange(srv, &cl, json);
        CHECK(ack && !strcmp(cJSON_GetObjectItem(ack, "t")->valuestring, "ready_ack"), "%s: ready_ack", label);
        char sc[65];
        snprintf(sc, sizeof(sc), "%s", cJSON_GetObjectItem(ack, "sc")->valuestring);
        CHECK(!strcmp(cJSON_GetObjectItem(ack, "cc")->valuestring, "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"), "cc echo");
        cJSON_Delete(ack);
        snprintf(json, sizeof(json), "{\"v\":1,\"t\":\"next\",\"seq\":2,\"sc\":\"%s\"}", sc);
        cJSON *next = exchange(srv, &cl, json);
        CHECK(next && !strcmp(cJSON_GetObjectItem(next, "phase")->valuestring, "queued"), "%s: next_r", label);
        cJSON_Delete(next);
        snprintf(json, sizeof(json), "{\"v\":1,\"t\":\"accept\",\"seq\":3,\"sc\":\"%s\",\"id\":\"task-1\",\"idem\":\"goal-1\"}", sc);
        cJSON *acc = exchange(srv, &cl, json);
        CHECK(acc && !strcmp(cJSON_GetObjectItem(acc, "result")->valuestring, "applied"), "%s: accept", label);
        cJSON_Delete(acc);
        snprintf(json, sizeof(json),
                 "{\"v\":1,\"t\":\"complete\",\"seq\":4,\"sc\":\"%s\",\"id\":\"task-1\",\"idem\":\"goal-1\",\"output\":\"done\",\"truncated\":false}", sc);
        cJSON *done = exchange(srv, &cl, json);
        CHECK(done && !strcmp(cJSON_GetObjectItem(done, "phase")->valuestring, "completed"), "%s: complete", label);
        cJSON_Delete(done);
        /* Replay of an old sequence number closes the session (TLS keeps
         * order; the application sequence rejects a resent request). */
        snprintf(json, sizeof(json), "{\"v\":1,\"t\":\"next\",\"seq\":2,\"sc\":\"%s\"}", sc);
        cJSON *bad = exchange(srv, &cl, json);
        CHECK(bad && !strcmp(cJSON_GetObjectItem(bad, "code")->valuestring, "bad_sequence"), "%s: replay", label);
        cJSON_Delete(bad);
        CHECK(pdsh_ss_conn_poll(srv, clock_ms) == PDSH_SS_CONN_CLOSED, "%s: closed after fatal", label);
        cJSON *local = pdsh_task_store_result("task-1");
        CHECK(local && !strcmp(cJSON_GetObjectItem(local, "phase")->valuestring, "completed"), "%s: durable", label);
        cJSON_Delete(local);
    }
    if (!ok) {
        CHECK(pdsh_ss_conn_poll(srv, clock_ms) == PDSH_SS_CONN_CLOSED, "%s: server not closed", label);
        /* Deliver whatever the server sent and read the alert it carried. */
        uint8_t sink[256];
        int rr = r ? r : mbedtls_ssl_read(&cl, sink, sizeof(sink));
        client_error = rr;
        if (rr == MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE) client_alert = mbedtls_ssl_get_fatal_alert(&cl);
        if (getenv("PDSH_TLS_DEBUG")) fprintf(stderr, "[%s] client read -0x%04x s2c=%zu\n", label, (unsigned)-rr, s2c.len);
        CHECK(rr < 0 && rr != MBEDTLS_ERR_SSL_WANT_READ, "%s: client saw no failure (%d)", label, rr);
    }
    *server_reason = pdsh_ss_conn_reason(srv);
    *server_alert = pdsh_ss_conn_alert(srv);
    mbedtls_ssl_free(&cl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_x509_crt_free(&own);
    mbedtls_x509_crt_free(&anchor);
    mbedtls_pk_free(&pk);
    pdsh_ss_conn_free(srv);
    return ok;
}

static int loopback(void) {
    fake_nvs_reset();
    clock_ms = 5000000;
    CHECK(pdsh_identity_init(), "device identity");
    CHECK(pdsh_identity_probe(device_fp) == PDSH_IDENTITY_OK, "probe");
    CHECK(pdsh_cert_build(pdsh_identity_key(), true, device_cert, sizeof(device_cert), &device_cert_len), "device cert");
    const uint8_t *der[1] = {device_cert};
    CHECK(pdsh_cert_verify_chain(der, &device_cert_len, 1, device_fp) == PDSH_CERT_OK, "own certificate conforms");
    mbedtls_x509_crt parsed;
    mbedtls_x509_crt_init(&parsed);
    CHECK(mbedtls_x509_crt_parse_der(&parsed, device_cert, device_cert_len) == 0 && parsed.version == 3 &&
              parsed.serial.len == 1 && parsed.serial.p[0] == 1 && parsed.valid_from.year == 2026 &&
              parsed.valid_to.year == 9999 && parsed.subject_raw.len == parsed.issuer_raw.len &&
              !memcmp(parsed.subject_raw.p, parsed.issuer_raw.p, parsed.subject_raw.len),
          "producer profile");
    mbedtls_x509_crt_free(&parsed);
    phone_key = new_key();
    other_key = new_key();
    key_fp(phone_key, phone_fp);
    pdsh_ss_server_cfg_t cfg = {device_cert, device_cert_len, pdsh_identity_key(), &pdsh_ss_timers_v1, real_random};
    const char *reason;
    int alert, cases = 0;

    client_case_t good = {.enrolled_phone = true};
    CHECK(run_case(&cfg, &good, "happy", true, &reason, &alert), "happy handshake (%s)", reason);
    cases++;

    struct {
        const char *label;
        client_case_t c;
        const char *reason;
        int alert, client_alert;
    } neg[] = {
        {"unenrolled-phone-key", {.enrolled_phone = false}, "pin_mismatch", 0, MBEDTLS_SSL_ALERT_MSG_BAD_CERT},
        {"wrong-private-key", {.enrolled_phone = true, .wrong_private_key = true}, NULL, 0, MBEDTLS_SSL_ALERT_MSG_DECRYPT_ERROR},
        {"ca-certificate", {.enrolled_phone = true, .variant = VARIANT_CA}, "ca_true", 0, MBEDTLS_SSL_ALERT_MSG_BAD_CERT},
        {"eku-present", {.enrolled_phone = true, .variant = VARIANT_EKU}, "eku_present", 0, MBEDTLS_SSL_ALERT_MSG_BAD_CERT},
        {"unknown-critical-extension", {.enrolled_phone = true, .variant = VARIANT_CRITICAL}, NULL, 0, MBEDTLS_SSL_ALERT_MSG_BAD_CERT},
        {"missing-client-certificate", {.enrolled_phone = true, .no_cert = true}, NULL, 0, MBEDTLS_SSL_ALERT_MSG_CERT_REQUIRED},
        {"revoked-record", {.enrolled_phone = true, .revoked = true}, "pin_mismatch", 0, MBEDTLS_SSL_ALERT_MSG_BAD_CERT},
        {"tls12-only-client", {.enrolled_phone = true, .max_version = 2}, NULL, MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE, -1},
        {"disallowed-cipher", {.enrolled_phone = true, .suite = MBEDTLS_TLS1_3_AES_256_GCM_SHA384}, NULL, 0, MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE},
        {"group-x25519-only", {.enrolled_phone = true, .groups = {MBEDTLS_SSL_IANA_TLS_GROUP_X25519, 0, 0}}, NULL,
         MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE, -1},
        {"p384-share-first-no-hrr", {.enrolled_phone = true, .groups = {MBEDTLS_SSL_IANA_TLS_GROUP_SECP384R1, MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1, 0}},
         NULL, MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE, -1},
        {"no-alpn", {.enrolled_phone = true, .no_alpn = true}, NULL, MBEDTLS_SSL_ALERT_MSG_NO_APPLICATION_PROTOCOL, -1},
        {"other-alpn", {.enrolled_phone = true, .alpn = {"pdsh-ble-task/2", NULL, NULL}}, NULL, MBEDTLS_SSL_ALERT_MSG_NO_APPLICATION_PROTOCOL, -1},
        {"extra-alpn", {.enrolled_phone = true, .alpn = {PDSH_SS_ALPN, "h2", NULL}}, NULL, MBEDTLS_SSL_ALERT_MSG_NO_APPLICATION_PROTOCOL, -1},
        {"psk-offered", {.enrolled_phone = true, .psk = true}, NULL, MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE, -1},
    };
    for (size_t i = 0; i < sizeof(neg) / sizeof(neg[0]); i++) {
        bool ok = run_case(&cfg, &neg[i].c, neg[i].label, false, &reason, &alert);
        CHECK(!ok, "%s: handshake must fail", neg[i].label);
        if (neg[i].reason) CHECK(!strcmp(reason, neg[i].reason), "%s: reason %s", neg[i].label, reason);
        if (neg[i].alert) CHECK(alert == neg[i].alert, "%s: alert %d", neg[i].label, alert);
        int want_client = neg[i].client_alert >= 0 ? neg[i].client_alert : neg[i].alert;
        /* mbedTLS 4.1 as a TLS 1.3 server encrypts an alert about the client
         * flight under its handshake keys although it already sent Finished;
         * a client that switched keys sees bad_record_mac instead of the
         * alert. Either way the handshake fails closed (recorded finding). */
        bool post_finished = neg[i].client_alert > 0 && neg[i].alert == 0 && client_error == MBEDTLS_ERR_SSL_INVALID_MAC;
        if (want_client > 0 && !post_finished)
            CHECK(client_alert == want_client, "%s: client saw alert %d", neg[i].label, client_alert);
        printf("  loopback negative %-28s rejected (server: %s; client: %s %d)\n", neg[i].label, reason,
               post_finished ? "bad_record_mac; expected alert undecryptable" : "alert", want_client);
        cases++;
    }
    /* After all negatives the enrolled phone still works (no state damage). */
    CHECK(run_case(&cfg, &good, "happy-again", true, &reason, &alert), "happy again");
    cases++;
    return cases;
}

int main(int argc, char **argv) {
    const char *files[6] = {0};
    for (int i = 1; i + 1 < argc; i += 2) {
        const char *k = argv[i];
        int slot = !strcmp(k, "--identifiers") ? 0 : !strcmp(k, "--certificates") ? 1 : !strcmp(k, "--frames") ? 2
                   : !strcmp(k, "--messages") ? 3 : !strcmp(k, "--sequences") ? 4 : -1;
        CHECK(slot >= 0, "unknown option %s", k);
        files[slot] = argv[i + 1];
    }
    for (int i = 0; i < 5; i++) CHECK(files[i], "missing golden file option");
    CHECK(psa_crypto_init() == PSA_SUCCESS, "psa");
    int na = 0, steps = 0;
    int ids = identifiers(files[0], &na), certs = certificates(files[1]), fr = frames(files[2]), msgs = messages(files[3]);
    int seqs = sequences(files[4], &steps);
    printf("secure identifiers: %d PASS (%d phone-side token rows not applicable); certificates: %d PASS; "
           "frames: %d PASS; messages: %d PASS; device sequences: %d (%d steps) PASS\n",
           ids - na, na, certs, fr, msgs, seqs, steps);
    int cases = loopback();
    printf("TLS 1.3 loopback (real server profile vs independent mbedTLS client): %d cases PASS\n", cases);
    return 0;
}

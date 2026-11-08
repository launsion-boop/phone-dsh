// SPDX-License-Identifier: MIT
#include "pdsh_secure_session.h"
#include "cJSON.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "pdsh_secure_cert.h"
#include "pdsh_task_store.h"
#include "psa/crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const pdsh_ss_timers_t pdsh_ss_timers_v2 = {15000, 10000, 90000, 600000};

/* ======================= application layer ======================= */

static bool expired(const pdsh_ss_app_t *app, uint64_t now_ms);
static void send_json(pdsh_ss_app_t *app, cJSON *msg) {
    char *text = msg ? cJSON_PrintUnformatted(msg) : NULL;
    cJSON_Delete(msg);
    if (!text) return;
    size_t n = strlen(text);
    uint8_t *frame = malloc(n + 2);
    if (frame && pdsh_frame_encode((const uint8_t *)text, n, frame) && app->emit)
        app->emit(app->emit_ctx, frame, n + 2);
    free(frame);
    free(text);
}
static cJSON *reply(const char *t, uint32_t re) {
    cJSON *o = cJSON_CreateObject();
    if (!o || !cJSON_AddNumberToObject(o, "v", 1) || !cJSON_AddStringToObject(o, "t", t) ||
        !cJSON_AddNumberToObject(o, "re", re)) {
        cJSON_Delete(o);
        return NULL;
    }
    return o;
}
static void send_error(pdsh_ss_app_t *app, pdsh_ss_error_t code, uint32_t re) {
    cJSON *o = reply("err", re);
    if (o && !cJSON_AddStringToObject(o, "code", pdsh_ss_error_name(code))) {
        cJSON_Delete(o);
        o = NULL;
    }
    send_json(app, o);
}
static void close_app(pdsh_ss_app_t *app, pdsh_ss_error_t code, uint32_t re) {
    if (app->state == PDSH_SS_APP_CLOSED) return;
    if (code != PDSH_ERR_NONE) send_error(app, code, re);
    app->state = PDSH_SS_APP_CLOSED;
    app->close_code = code;
    pdsh_frame_reset(&app->frames); /* discard buffered bytes */
}

/* Authority as captured: still committed, same eid/phone/rev, not revoked. */
static bool authority(const pdsh_ss_app_t *app) {
    pdsh_enroll_durable_t now;
    return pdsh_enroll_session_record(&now) && !strcmp(now.eid, app->record.eid) &&
           !strcmp(now.phone, app->record.phone) && !strcmp(now.device, app->record.device) &&
           now.rev == app->record.rev;
}

bool pdsh_ss_app_start(pdsh_ss_app_t *app, const char *verified_phone_fp, uint64_t now_ms,
                       const pdsh_ss_timers_t *timers, pdsh_ss_random_fn random, pdsh_ss_emit_fn emit,
                       void *emit_ctx) {
    memset(app, 0, sizeof(*app));
    app->state = PDSH_SS_APP_CLOSED;
    app->timers = timers ? timers : &pdsh_ss_timers_v2;
    app->random = random;
    app->emit = emit;
    app->emit_ctx = emit_ctx;
    if (!verified_phone_fp || !random || !pdsh_enroll_session_record(&app->record) ||
        strcmp(app->record.phone, verified_phone_fp))
        return false;
    snprintf(app->device_id, sizeof(app->device_id), "ble:%s", app->record.device);
    snprintf(app->phone_id, sizeof(app->phone_id), "phone:%s", app->record.phone);
    app->state = PDSH_SS_APP_VERIFIED;
    app->started_ms = app->last_ms = now_ms;
    return true;
}

static void dispatch(pdsh_ss_app_t *app, const pdsh_msg_t *m) {
    const char *me = app->phone_id;
    cJSON *out = NULL;
    if (m->type == PDSH_MSG_NEXT) {
        cJSON *offer = pdsh_task_store_offer(me);
        if (!offer) {
            close_app(app, PDSH_ERR_STORAGE, m->seq);
            return;
        }
        out = reply("next_r", m->seq);
        cJSON *task = cJSON_DetachItemFromObjectCaseSensitive(offer, "task");
        cJSON *phase = cJSON_DetachItemFromObjectCaseSensitive(offer, "phase");
        cJSON_Delete(offer);
        if (!out || !task || !phase || !cJSON_AddItemToObject(out, "task", task)) {
            cJSON_Delete(task);
            cJSON_Delete(phase);
            cJSON_Delete(out);
            close_app(app, PDSH_ERR_INTERNAL, m->seq);
            return;
        }
        if (!cJSON_AddItemToObject(out, "phase", phase)) {
            cJSON_Delete(phase);
            cJSON_Delete(out);
            close_app(app, PDSH_ERR_INTERNAL, m->seq);
            return;
        }
        send_json(app, out);
        return;
    }
    if (m->type == PDSH_MSG_STATUS) {
        const char *phase;
        bool mine;
        cJSON *outcome;
        pdsh_store_result_t r = pdsh_task_store_status(m->id, m->idem, me, &phase, &mine, &outcome);
        if (r == PDSH_STORE_CONFLICT) {
            send_error(app, PDSH_ERR_CONFLICT, m->seq);
            return;
        }
        if (r != PDSH_STORE_APPLIED) {
            close_app(app, PDSH_ERR_STORAGE, m->seq);
            return;
        }
        out = reply("status_r", m->seq);
        if (!out || !cJSON_AddStringToObject(out, "phase", phase) || !cJSON_AddBoolToObject(out, "mine", mine) ||
            (outcome && !cJSON_AddItemToObject(out, "outcome", outcome))) {
            cJSON_Delete(out);
            close_app(app, PDSH_ERR_INTERNAL, m->seq);
            return;
        }
        send_json(app, out);
        return;
    }
    const char *action = m->type == PDSH_MSG_ACCEPT ? "accept" : m->type == PDSH_MSG_COMPLETE ? "complete" : "fail";
    cJSON *outcome = NULL;
    if (m->type == PDSH_MSG_COMPLETE) {
        outcome = cJSON_CreateObject();
        if (outcome) {
            cJSON_AddItemToObject(outcome, "output", cJSON_Duplicate(m->output, true));
            cJSON_AddItemToObject(outcome, "truncated", cJSON_Duplicate(m->truncated, true));
        }
    } else if (m->type == PDSH_MSG_FAIL) {
        outcome = cJSON_CreateObject();
        if (outcome) cJSON_AddItemToObject(outcome, "failure", cJSON_Duplicate(m->failure, true));
    }
    const char *phase = NULL;
    pdsh_store_result_t r = pdsh_task_store_secure(action, m->id, m->idem, me, outcome, &phase);
    cJSON_Delete(outcome);
    pdsh_ss_error_t err = PDSH_ERR_NONE;
    switch (r) {
    case PDSH_STORE_APPLIED:
    case PDSH_STORE_DUPLICATE:
        out = reply("r", m->seq);
        if (!out || !cJSON_AddStringToObject(out, "result", r == PDSH_STORE_APPLIED ? "applied" : "duplicate") ||
            !cJSON_AddStringToObject(out, "phase", phase)) {
            cJSON_Delete(out);
            close_app(app, PDSH_ERR_INTERNAL, m->seq);
            return;
        }
        send_json(app, out);
        return;
    case PDSH_STORE_UNKNOWN_TASK: err = PDSH_ERR_UNKNOWN_TASK; break;
    case PDSH_STORE_CONFLICT: err = PDSH_ERR_CONFLICT; break;
    case PDSH_STORE_WRONG_OWNER: err = PDSH_ERR_WRONG_OWNER; break;
    case PDSH_STORE_INVALID_TRANSITION: err = PDSH_ERR_INVALID_TRANSITION; break;
    default:
        close_app(app, PDSH_ERR_STORAGE, m->seq); /* fatal; the slot is unchanged */
        return;
    }
    send_error(app, err, m->seq);
}

static void handle(pdsh_ss_app_t *app, const uint8_t *payload, size_t n, uint64_t now_ms) {
    pdsh_msg_t m;
    if (!pdsh_msg_decode(payload, n, PDSH_DIR_C2S, &m)) {
        close_app(app, PDSH_ERR_MALFORMED, 0);
        return;
    }
    if (m.type == PDSH_MSG_ERR) { /* a client err closes without reply */
        close_app(app, PDSH_ERR_NONE, 0);
    } else if (app->state == PDSH_SS_APP_VERIFIED) {
        if (m.type != PDSH_MSG_READY_REQ) close_app(app, PDSH_ERR_NOT_READY, m.seq);
        else if (m.seq != 1) close_app(app, PDSH_ERR_BAD_SEQUENCE, m.seq);
        else if (strcmp(m.device, app->device_id) || strcmp(m.phone, app->phone_id) || strcmp(m.eid, app->record.eid))
            close_app(app, PDSH_ERR_RECORD_MISMATCH, m.seq);
        else if (!authority(app)) close_app(app, PDSH_ERR_REVOKED, m.seq);
        else {
            uint8_t sc[32];
            if (!app->random(sc, sizeof(sc))) {
                close_app(app, PDSH_ERR_INTERNAL, m.seq); /* no entropy source: no challenge */
                pdsh_msg_free(&m);
                return;
            }
            pdsh_hex_encode(sc, sizeof(sc), app->sc);
            cJSON *ack = reply("ready_ack", 1);
            if (ack && cJSON_AddStringToObject(ack, "device", app->device_id) &&
                cJSON_AddStringToObject(ack, "phone", app->phone_id) &&
                cJSON_AddStringToObject(ack, "eid", app->record.eid) && cJSON_AddStringToObject(ack, "cc", m.cc) &&
                cJSON_AddStringToObject(ack, "sc", app->sc)) {
                send_json(app, ack);
                app->state = PDSH_SS_APP_READY;
                app->last_seq = 1;
                app->last_ms = now_ms;
            } else {
                cJSON_Delete(ack);
                close_app(app, PDSH_ERR_INTERNAL, m.seq);
            }
        }
    } else if (app->state == PDSH_SS_APP_READY) {
        if (m.type == PDSH_MSG_READY_REQ || m.seq != app->last_seq + 1)
            close_app(app, PDSH_ERR_BAD_SEQUENCE, m.seq);
        else if (strcmp(m.sc, app->sc)) close_app(app, PDSH_ERR_BAD_CHALLENGE, m.seq);
        else {
            /* The authority check and the store mutation are one critical
             * section with respect to revoke/identity-reset. */
            pdsh_enroll_lock();
            if (!authority(app)) close_app(app, PDSH_ERR_REVOKED, m.seq);
            else {
                app->last_seq = m.seq;
                app->last_ms = now_ms;
                dispatch(app, &m);
            }
            pdsh_enroll_unlock();
        }
    }
    pdsh_msg_free(&m);
}

bool pdsh_ss_app_input(pdsh_ss_app_t *app, const uint8_t *data, size_t n, uint64_t now_ms) {
    /* A request arriving after the lifetime is never dispatched. */
    if (app->state != PDSH_SS_APP_CLOSED && expired(app, now_ms)) close_app(app, PDSH_ERR_NONE, 0);
    while (app->state != PDSH_SS_APP_CLOSED && n) {
        const uint8_t *payload;
        size_t len;
        pdsh_frame_result_t r = pdsh_frame_next(&app->frames, &data, &n, &payload, &len);
        if (r == PDSH_FRAME_LIMIT) close_app(app, PDSH_ERR_LIMIT, 0);
        else if (r == PDSH_FRAME_PAYLOAD) {
            /* The payload stays valid until the next pdsh_frame_next call. */
            handle(app, payload, len, now_ms);
        }
    }
    return app->state != PDSH_SS_APP_CLOSED;
}

static bool expired(const pdsh_ss_app_t *app, uint64_t now_ms) {
    return now_ms - app->started_ms >= app->timers->lifetime_ms;
}
bool pdsh_ss_app_tick(pdsh_ss_app_t *app, uint64_t now_ms) {
    if (app->state == PDSH_SS_APP_CLOSED) return false;
    /* Immediate close only for the RAM revocation flag / a non-committed
     * record; a changed committed tuple is caught before the next request. */
    if (!pdsh_enroll_session_record(NULL)) close_app(app, PDSH_ERR_REVOKED, 0);
    else if (expired(app, now_ms)) close_app(app, PDSH_ERR_NONE, 0); /* close_notify only */
    else if (app->state == PDSH_SS_APP_VERIFIED && now_ms - app->started_ms >= app->timers->ready_ms)
        close_app(app, PDSH_ERR_TIMEOUT, 0);
    else if (app->state == PDSH_SS_APP_READY && now_ms - app->last_ms >= app->timers->idle_ms)
        close_app(app, PDSH_ERR_TIMEOUT, 0);
    return app->state != PDSH_SS_APP_CLOSED;
}

void pdsh_ss_app_close(pdsh_ss_app_t *app) {
    app->state = PDSH_SS_APP_CLOSED;
    pdsh_frame_reset(&app->frames); /* truncated bytes are never delivered */
}

/* ======================= TLS connection ======================= */

/* §5 per-session budget (<= 32 KiB): transport input holds one ClientHello
 * record; transport output is two 512-byte SDUs (mbedTLS resumes partial
 * record writes on WANT_WRITE); a response that does not fit waits as one
 * pending frame; mbedTLS buffers 4352 + 4096. */
#define RX_CAP 1024
#define TX_CAP 1024

struct pdsh_ss_conn {
    mbedtls_ssl_config conf;
    mbedtls_ssl_context ssl;
    mbedtls_x509_crt own;
    mbedtls_pk_context key;
    const pdsh_ss_server_cfg_t *cfg;
    pdsh_ss_conn_state_t state;
    uint64_t opened_ms;
    uint8_t rx[RX_CAP], tx[TX_CAP];
    size_t rx_len, tx_len;
    bool eof, hello_checked, closing;
    int alert;
    const char *reason;
    char verified_pin[65];
    uint8_t *pend; /* response frames not yet accepted by mbedtls_ssl_write */
    size_t pend_len, pend_off;
    pdsh_ss_app_t app;
};

static const int suites[] = {MBEDTLS_TLS1_3_AES_128_GCM_SHA256, 0};
static const uint16_t groups[] = {MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1, 0};
static const uint16_t sig_algs[] = {MBEDTLS_TLS1_3_SIG_ECDSA_SECP256R1_SHA256, MBEDTLS_TLS1_3_SIG_NONE};
static const char *alpn[] = {PDSH_SS_ALPN, NULL};

static int bio_send(void *ctx, const unsigned char *buf, size_t len) {
    pdsh_ss_conn_t *c = ctx;
    size_t room = TX_CAP - c->tx_len, n = len < room ? len : room;
    if (!n) return MBEDTLS_ERR_SSL_WANT_WRITE;
    memcpy(c->tx + c->tx_len, buf, n);
    c->tx_len += n;
    return (int)n;
}
static int bio_recv(void *ctx, unsigned char *buf, size_t len) {
    pdsh_ss_conn_t *c = ctx;
    if (!c->rx_len) return c->eof ? MBEDTLS_ERR_SSL_CONN_EOF : MBEDTLS_ERR_SSL_WANT_READ;
    size_t n = len < c->rx_len ? len : c->rx_len;
    memcpy(buf, c->rx, n);
    memmove(c->rx, c->rx + n, c->rx_len - n);
    c->rx_len -= n;
    return (int)n;
}

/* §6.2: clear exactly not-trusted/expired/not-yet-valid, then enforce rules
 * 1-5 with the pin of the committed record. A rejection is reported with the
 * identity-mismatch flag so that mbedTLS sends bad_certificate. */
static int verify_peer(void *ctx, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
    pdsh_ss_conn_t *c = ctx;
    *flags &= ~(uint32_t)(MBEDTLS_X509_BADCERT_NOT_TRUSTED | MBEDTLS_X509_BADCERT_EXPIRED |
                          MBEDTLS_X509_BADCERT_FUTURE);
    if (depth != 0) return 0;
    const uint8_t *der[4];
    size_t len[4], count = 0;
    for (const mbedtls_x509_crt *p = crt; p && count < 4; p = p->next, count++) {
        der[count] = p->raw.p;
        len[count] = p->raw.len;
    }
    /* count > 1 is reported as chain_length by the verifier. */
    pdsh_enroll_durable_t rec;
    pdsh_cert_status_t st = PDSH_CERT_PIN_MISMATCH;
    if (pdsh_enroll_session_record(&rec)) st = pdsh_cert_verify_chain(der, len, count, rec.phone);
    c->reason = pdsh_cert_status_name(st);
    if (st == PDSH_CERT_OK) snprintf(c->verified_pin, sizeof(c->verified_pin), "%s", rec.phone);
    else *flags |= MBEDTLS_X509_BADCERT_CN_MISMATCH;
    return 0;
}

static void send_alert_plain(pdsh_ss_conn_t *c, uint8_t description) {
    const uint8_t alert[] = {0x15, 0x03, 0x03, 0x00, 0x02, 0x02, description};
    if (TX_CAP - c->tx_len >= sizeof(alert)) {
        memcpy(c->tx + c->tx_len, alert, sizeof(alert));
        c->tx_len += sizeof(alert);
    }
    c->alert = description;
}

/* ClientHello profile gate (§6.1) run before mbedTLS sees the hello: no PSK,
 * early data, SNI, max_fragment_length, record_size_limit or post-handshake
 * auth; a secp256r1 key share is mandatory (no HelloRetryRequest); ALPN is
 * exactly pdsh-ble-task/1. Returns 1 ok, 0 need more bytes, or -alert. */
static int check_client_hello(const uint8_t *p, size_t n) {
    if (n < 5) return 0;
    if (p[0] != 0x16) return -MBEDTLS_SSL_ALERT_MSG_UNEXPECTED_MESSAGE;
    size_t rec = (size_t)p[3] << 8 | p[4];
    if (rec > 16384) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR;
    if (n < 5 + rec) return 0;
    const uint8_t *h = p + 5, *end = h + rec;
    if (rec < 4 || h[0] != 0x01) return -MBEDTLS_SSL_ALERT_MSG_UNEXPECTED_MESSAGE;
    size_t body = (size_t)h[1] << 16 | (size_t)h[2] << 8 | h[3];
    if (body + 4 != rec) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR; /* one hello per first record */
    const uint8_t *q = h + 4;
#define NEED(k) do { if ((size_t)(end - q) < (size_t)(k)) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR; } while (0)
    NEED(35);
    q += 34;
    size_t sid = *q++;
    NEED(sid + 2);
    q += sid;
    size_t cs = (size_t)q[0] << 8 | q[1];
    q += 2;
    NEED(cs + 1);
    q += cs;
    size_t comp = *q++;
    NEED(comp + 2);
    q += comp;
    size_t ext_len = (size_t)q[0] << 8 | q[1];
    q += 2;
    NEED(ext_len);
    const uint8_t *ext_end = q + ext_len;
    bool p256_share = false, alpn_ok = false, alpn_seen = false, tls13 = false, forbidden = false;
    while (q < ext_end) {
        if (ext_end - q < 4) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR;
        unsigned type = (unsigned)q[0] << 8 | q[1];
        size_t len = (size_t)q[2] << 8 | q[3];
        q += 4;
        if ((size_t)(ext_end - q) < len) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR;
        const uint8_t *e = q, *e_end = q + len;
        switch (type) {
        case 0:  /* server_name */
        case 1:  /* max_fragment_length */
        case 28: /* record_size_limit */
        case 41: /* pre_shared_key */
        case 42: /* early_data */
        case 45: /* psk_key_exchange_modes */
        case 49: /* post_handshake_auth */
            forbidden = true;
            break;
        case 43: /* supported_versions */
            if (len < 1 || (size_t)e[0] + 1 != len || e[0] % 2) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR;
            for (size_t i = 1; i + 1 < len; i += 2)
                if (e[i] == 0x03 && e[i + 1] == 0x04) tls13 = true;
            break;
        case 51: { /* key_share */
            if (len < 2) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR;
            e += 2;
            while (e_end - e >= 4) {
                unsigned group = (unsigned)e[0] << 8 | e[1];
                size_t klen = (size_t)e[2] << 8 | e[3];
                e += 4;
                if ((size_t)(e_end - e) < klen) return -MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR;
                if (group == MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1 && klen == 65) p256_share = true;
                e += klen;
            }
            break;
        }
        case 16: { /* ALPN */
            alpn_seen = true;
            size_t want = strlen(PDSH_SS_ALPN);
            alpn_ok = len == want + 3 && ((size_t)e[0] << 8 | e[1]) == want + 1 && e[2] == want &&
                      !memcmp(e + 3, PDSH_SS_ALPN, want);
            break;
        }
        default:
            break;
        }
        q = e_end;
    }
#undef NEED
    if (!tls13) return -MBEDTLS_SSL_ALERT_MSG_PROTOCOL_VERSION;
    if (forbidden) return -MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE;
    if (!p256_share) return -MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE;
    if (!alpn_seen || !alpn_ok) return -MBEDTLS_SSL_ALERT_MSG_NO_APPLICATION_PROTOCOL;
    return 1;
}

/* Writes pending response bytes as far as the transport output allows; on
 * WANT_WRITE mbedTLS is called again with the same bytes later. */
static void flush_pending(pdsh_ss_conn_t *c) {
    while (c->pend && c->pend_off < c->pend_len) {
        int r = mbedtls_ssl_write(&c->ssl, c->pend + c->pend_off, c->pend_len - c->pend_off);
        if (r == MBEDTLS_ERR_SSL_WANT_WRITE || r == MBEDTLS_ERR_SSL_WANT_READ) return;
        if (r <= 0) {
            c->closing = true;
            c->reason = "write";
            break;
        }
        c->pend_off += (size_t)r;
    }
    free(c->pend);
    c->pend = NULL;
    c->pend_len = c->pend_off = 0;
}
static void app_emit(void *ctx, const uint8_t *frame, size_t n) {
    pdsh_ss_conn_t *c = ctx;
    uint8_t *grown = realloc(c->pend, c->pend_len + n); /* one response, rarely plus an err */
    if (!grown) {
        c->closing = true;
        c->reason = "memory";
        return;
    }
    memcpy(grown + c->pend_len, frame, n);
    c->pend = grown;
    c->pend_len += n;
    flush_pending(c);
}

pdsh_ss_conn_t *pdsh_ss_conn_new(const pdsh_ss_server_cfg_t *cfg, uint64_t now_ms) {
    if (!cfg || !cfg->cert_der || !cfg->random || psa_crypto_init() != PSA_SUCCESS) return NULL;
    pdsh_ss_conn_t *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->cfg = cfg;
    c->opened_ms = now_ms;
    c->state = PDSH_SS_CONN_HANDSHAKE;
    c->reason = "open";
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_ssl_init(&c->ssl);
    mbedtls_x509_crt_init(&c->own);
    mbedtls_pk_init(&c->key);
    int r = mbedtls_x509_crt_parse_der(&c->own, cfg->cert_der, cfg->cert_len);
    if (!r) r = mbedtls_pk_wrap_psa(&c->key, (mbedtls_svc_key_id_t)cfg->key_id);
    if (!r) r = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM,
                                            MBEDTLS_SSL_PRESET_DEFAULT);
    if (!r) {
        mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_3);
        mbedtls_ssl_conf_max_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_3);
        mbedtls_ssl_conf_ciphersuites(&c->conf, suites);
        mbedtls_ssl_conf_groups(&c->conf, groups);
        mbedtls_ssl_conf_sig_algs(&c->conf, sig_algs);
        mbedtls_ssl_conf_tls13_key_exchange_modes(&c->conf, MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL);
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        /* Trust is the pin only; the own certificate is a placeholder anchor
         * that mbedTLS requires and that no peer certificate chains to. */
        mbedtls_ssl_conf_ca_chain(&c->conf, &c->own, NULL);
        mbedtls_ssl_conf_cert_req_ca_list(&c->conf, MBEDTLS_SSL_CERT_REQ_CA_LIST_DISABLED);
        mbedtls_ssl_conf_verify(&c->conf, verify_peer, c);
#if defined(MBEDTLS_SSL_SESSION_TICKETS) && defined(MBEDTLS_SSL_SRV_C)
        mbedtls_ssl_conf_new_session_tickets(&c->conf, 0);
#endif
#if defined(MBEDTLS_SSL_EARLY_DATA)
        mbedtls_ssl_conf_early_data(&c->conf, MBEDTLS_SSL_EARLY_DATA_DISABLED);
#endif
        r = mbedtls_ssl_conf_alpn_protocols(&c->conf, alpn);
    }
    if (!r) r = mbedtls_ssl_conf_own_cert(&c->conf, &c->own, &c->key);
    if (!r) r = mbedtls_ssl_setup(&c->ssl, &c->conf);
    if (r) {
        pdsh_ss_conn_free(c);
        return NULL;
    }
    mbedtls_ssl_set_bio(&c->ssl, c, bio_send, bio_recv, NULL);
    return c;
}

void pdsh_ss_conn_free(pdsh_ss_conn_t *c) {
    if (!c) return;
    mbedtls_ssl_free(&c->ssl);
    mbedtls_ssl_config_free(&c->conf);
    mbedtls_x509_crt_free(&c->own);
    mbedtls_pk_free(&c->key);
    free(c->pend);
    memset(c, 0, sizeof(*c));
    free(c);
}

bool pdsh_ss_conn_rx(pdsh_ss_conn_t *c, const uint8_t *data, size_t n) {
    if (c->state == PDSH_SS_CONN_CLOSED) return true; /* discarded */
    if (n > RX_CAP - c->rx_len) return false;
    memcpy(c->rx + c->rx_len, data, n);
    c->rx_len += n;
    return true;
}
size_t pdsh_ss_conn_rx_free(const pdsh_ss_conn_t *c) { return RX_CAP - c->rx_len; }
void pdsh_ss_conn_eof(pdsh_ss_conn_t *c) { c->eof = true; }
size_t pdsh_ss_conn_tx(pdsh_ss_conn_t *c, uint8_t *out, size_t cap) {
    size_t n = cap < c->tx_len ? cap : c->tx_len;
    memcpy(out, c->tx, n);
    memmove(c->tx, c->tx + n, c->tx_len - n);
    c->tx_len -= n;
    return n;
}
const char *pdsh_ss_conn_reason(const pdsh_ss_conn_t *c) { return c->reason; }
int pdsh_ss_conn_alert(const pdsh_ss_conn_t *c) { return c->alert; }

static void finish(pdsh_ss_conn_t *c, const char *reason) {
    if (c->state == PDSH_SS_CONN_OPEN) {
        pdsh_ss_app_close(&c->app);
        if (!c->alert) mbedtls_ssl_close_notify(&c->ssl); /* after a fatal alert, nothing more */
    }
    if (reason) c->reason = reason;
    c->state = PDSH_SS_CONN_CLOSED;
    c->rx_len = 0;
}

pdsh_ss_conn_state_t pdsh_ss_conn_poll(pdsh_ss_conn_t *c, uint64_t now_ms) {
    if (c->state == PDSH_SS_CONN_CLOSED) return c->state;
    if (c->state == PDSH_SS_CONN_HANDSHAKE) {
        if (now_ms - c->opened_ms >= c->cfg->timers->handshake_ms) {
            finish(c, "handshake_timeout");
            return c->state;
        }
        if (!c->hello_checked) {
            int r = check_client_hello(c->rx, c->rx_len);
            if (r == 0) {
                if (c->eof) finish(c, "eof");
                return c->state;
            }
            if (r < 0) {
                send_alert_plain(c, (uint8_t)-r);
                finish(c, "client_hello_profile");
                return c->state;
            }
            c->hello_checked = true;
        }
        int r = mbedtls_ssl_handshake(&c->ssl);
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (c->eof) finish(c, "eof");
            return c->state;
        }
        if (r != 0) {
            if (!strcmp(c->reason, "open") || !strcmp(c->reason, "ok")) c->reason = "handshake";
            finish(c, NULL);
            return c->state;
        }
        const char *selected = mbedtls_ssl_get_alpn_protocol(&c->ssl);
        if (!selected || strcmp(selected, PDSH_SS_ALPN)) {
            mbedtls_ssl_send_alert_message(&c->ssl, MBEDTLS_SSL_ALERT_LEVEL_FATAL,
                                           MBEDTLS_SSL_ALERT_MSG_NO_APPLICATION_PROTOCOL);
            finish(c, "alpn");
            return c->state;
        }
        if (!pdsh_ss_app_start(&c->app, c->verified_pin, now_ms, c->cfg->timers, c->cfg->random, app_emit, c)) {
            mbedtls_ssl_send_alert_message(&c->ssl, MBEDTLS_SSL_ALERT_LEVEL_FATAL, MBEDTLS_SSL_ALERT_MSG_BAD_CERT);
            finish(c, "record");
            return c->state;
        }
        c->state = PDSH_SS_CONN_OPEN;
        c->reason = "ready_wait";
    }
    uint8_t buf[1024];
    flush_pending(c);
    for (;;) {
        if (c->pend) break; /* one outstanding response: read on once it is out */
        int r = mbedtls_ssl_read(&c->ssl, buf, sizeof(buf));
        if (r > 0) {
            if (!pdsh_ss_app_input(&c->app, buf, (size_t)r, now_ms) || c->closing) break;
            continue;
        }
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (c->eof) {
                finish(c, "eof");
                return c->state;
            }
            break;
        }
        if (r == MBEDTLS_ERR_SSL_INVALID_RECORD) {
            /* mbedTLS 4.1 drops a record whose plaintext exceeds
             * MBEDTLS_SSL_IN_CONTENT_LEN (4352) without an alert; §6.1
             * requires record_overflow, so the board sends it. */
            c->alert = MBEDTLS_SSL_ALERT_MSG_RECORD_OVERFLOW;
            mbedtls_ssl_send_alert_message(&c->ssl, MBEDTLS_SSL_ALERT_LEVEL_FATAL, MBEDTLS_SSL_ALERT_MSG_RECORD_OVERFLOW);
            finish(c, "record_overflow");
            return c->state;
        }
        finish(c, r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY ? "peer_close" : "tls");
        return c->state;
    }
    if (c->closing) finish(c, "closed");
    else if (!pdsh_ss_app_tick(&c->app, now_ms)) {
        flush_pending(c); /* deliver the final err before close_notify */
        if (!c->pend) finish(c, "closed");
    }
    return c->state;
}

/* ======================= §5 LE CoC receive path ======================= */

static const char *const coc_names[] = {"",           "credit_overrun", "kframe_oversize", "sdu_oversize",
                                        "sdu_empty",  "sdu_overrun",    "kframe_short"};
const char *pdsh_coc_close_name(pdsh_coc_close_t reason) {
    return (unsigned)reason < sizeof(coc_names) / sizeof(coc_names[0]) ? coc_names[reason] : "";
}

bool pdsh_ss_coc_init(pdsh_ss_coc_t *coc, uint16_t mtu, uint16_t mps, uint8_t buffers) {
    memset(coc, 0, sizeof(*coc));
    if (buffers < 1 || buffers > PDSH_SS_COC_MAX_KFRAMES || mps < 23 || mps > 512 || mtu < 256) return false;
    coc->mtu = mtu;
    coc->mps = mps;
    coc->buffers = buffers;
    coc->peer_credits = buffers; /* initial grant = free K-frame buffers */
    return true;
}

static pdsh_coc_close_t coc_close(pdsh_ss_coc_t *coc, pdsh_coc_close_t reason) {
    coc->closed = reason;
    coc->held = coc->sdu_count = 0;
    coc->partial = false;
    coc->head = coc->used = 0;
    return reason;
}

pdsh_coc_close_t pdsh_ss_coc_kframe(pdsh_ss_coc_t *coc, const uint8_t *frame, size_t len) {
    if (coc->closed) return coc->closed;
    /* The credit check comes first: nothing is buffered or dereferenced for
     * a K-frame the peer had no credit for. */
    if (coc->peer_credits == 0) return coc_close(coc, PDSH_COC_CREDIT_OVERRUN);
    coc->peer_credits--;
    if (len > coc->mps) return coc_close(coc, PDSH_COC_KFRAME_OVERSIZE);
    const uint8_t *payload = frame;
    size_t n = len;
    if (!coc->partial) {
        if (len < 2) return coc_close(coc, PDSH_COC_KFRAME_SHORT);
        uint16_t sdu = (uint16_t)(frame[0] | frame[1] << 8);
        if (sdu == 0) return coc_close(coc, PDSH_COC_SDU_EMPTY);
        if (sdu > coc->mtu) return coc_close(coc, PDSH_COC_SDU_OVERSIZE);
        coc->partial = true;
        coc->partial_len = sdu;
        coc->partial_got = coc->partial_kframes = 0;
        payload += 2;
        n -= 2;
    }
    coc->held++;
    coc->partial_kframes++;
    if ((size_t)coc->partial_got + n > coc->partial_len) return coc_close(coc, PDSH_COC_SDU_OVERRUN);
    /* Invariant: held + peer_credits <= buffers, so the data fits the ring
     * (each K-frame payload <= mps, ring = buffers x 512 >= buffers x mps). */
    size_t cap = (size_t)coc->buffers * coc->mps;
    for (size_t i = 0; i < n; i++) coc->data[(coc->head + coc->used + i) % cap] = payload[i];
    coc->used += n;
    coc->partial_got += (uint16_t)n;
    if (coc->partial_got == coc->partial_len) {
        coc->sdu[coc->sdu_count].len = coc->partial_len;
        coc->sdu[coc->sdu_count].kframes = coc->partial_kframes;
        coc->sdu_count++;
        coc->partial = false;
    }
    return PDSH_COC_OK;
}

size_t pdsh_ss_coc_ready(const pdsh_ss_coc_t *coc) {
    return !coc->closed && coc->sdu_count ? coc->sdu[0].len : 0;
}

size_t pdsh_ss_coc_consume(pdsh_ss_coc_t *coc, uint8_t *out, size_t cap, uint8_t *credits) {
    *credits = 0;
    size_t len = pdsh_ss_coc_ready(coc);
    if (!len || cap < len) return 0;
    size_t ring = (size_t)coc->buffers * coc->mps;
    for (size_t i = 0; i < len; i++) out[i] = coc->data[(coc->head + i) % ring];
    coc->head = (coc->head + len) % ring;
    coc->used -= len;
    uint8_t frames = (uint8_t)coc->sdu[0].kframes;
    memmove(coc->sdu, coc->sdu + 1, sizeof(coc->sdu[0]) * (size_t)(coc->sdu_count - 1));
    coc->sdu_count--;
    coc->held -= frames;
    coc->peer_credits += frames; /* credits return only for freed buffers */
    *credits = frames;
    return len;
}

/* ======================= §5 admission and send ownership ======================= */

bool pdsh_ss_admit(pdsh_ss_admission_t *adm, uint16_t conn_handle, uint64_t now_ms) {
    if (adm->conn_handle != conn_handle) { /* a new LE connection starts fresh */
        adm->conn_handle = conn_handle;
        adm->failures = 0;
    }
    if (adm->open || now_ms < adm->backoff_until_ms || adm->failures >= 3) return false;
    adm->open = true;
    return true;
}
void pdsh_ss_released(pdsh_ss_admission_t *adm, bool reached_open, uint64_t now_ms) {
    adm->open = false;
    if (reached_open) {
        adm->failures = 0;
        return;
    }
    if (adm->failures < 255) adm->failures++;
    adm->backoff_until_ms = now_ms + 2000;
}

bool pdsh_ss_tx_can_send(const pdsh_ss_tx_t *tx) { return !tx->broken && !tx->stalled && tx->in_stack < 2; }
void pdsh_ss_tx_sent(pdsh_ss_tx_t *tx, pdsh_tx_rc_t rc, bool *caller_frees) {
    *caller_frees = false;
    switch (rc) {
    case PDSH_TX_RC_OK:
        break;
    case PDSH_TX_RC_STALLED:
        tx->stalled = true;
        tx->in_stack++;
        break;
    case PDSH_TX_RC_NOT_TAKEN:
        *caller_frees = true;
        tx->broken = true; /* the stream would have a gap: close, never resend */
        break;
    default:
        tx->broken = true; /* partially sent: close the CoC */
        break;
    }
}
void pdsh_ss_tx_unstalled(pdsh_ss_tx_t *tx, int status) {
    tx->stalled = false;
    if (tx->in_stack) tx->in_stack--;
    if (status) tx->broken = true;
}
void pdsh_ss_tx_disconnected(pdsh_ss_tx_t *tx) {
    tx->in_stack = 0;
    tx->stalled = false;
    tx->broken = true;
}

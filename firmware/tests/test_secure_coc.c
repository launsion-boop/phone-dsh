// SPDX-License-Identifier: MIT
/* secure-coc: the §5 pre-authentication receive path (pdsh_ss_coc_*) replayed
 * with golden/ble-secure-coc-cases.jsonl above a fake L2CAP, plus the host
 * layer of the coc-* conformance rows: admission (second CoC, 2 s back-off,
 * 3 failed handshakes per LE link), send ownership (BLE_HS_ESTALLED, link
 * loss during a queued send) and a ClientHello flood with reconnects. */
#include "mbedtls/ssl.h"
#include "pdsh_enroll.h"
#include "pdsh_identity.h"
#include "pdsh_secure_cert.h"
#include "pdsh_secure_session.h"
#include "psa/crypto.h"
#include "test_secure_support.h"
#include <stdlib.h>
#include <string.h>

static int vectors(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0;
    char *line;
    static pdsh_ss_coc_t coc;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        const cJSON *given = cJSON_GetObjectItem(row, "given");
        CHECK(pdsh_ss_coc_init(&coc, (uint16_t)cJSON_GetObjectItem(given, "mtu")->valueint,
                               (uint16_t)cJSON_GetObjectItem(given, "mps")->valueint,
                               (uint8_t)cJSON_GetObjectItem(given, "rx_kframes")->valueint),
              "%s: init", name);
        CHECK(coc.peer_credits == cJSON_GetObjectItem(row, "initial_credits")->valueint, "%s: initial credits", name);
        int i = 0;
        uint8_t next_byte = 0;
        const cJSON *step;
        cJSON_ArrayForEach(step, cJSON_GetObjectItem(row, "steps")) {
            const cJSON *peer = cJSON_GetObjectItem(step, "peer"), *expect = cJSON_GetObjectItem(step, "expect");
            const char *op = cJSON_GetObjectItem(peer, "op")->valuestring;
            int credits = 0;
            const char *closed = NULL;
            cJSON *delivered = cJSON_CreateArray();
            if (!strcmp(op, "kframe")) {
                static uint8_t frame[70000];
                size_t n = 0;
                const cJSON *sdu = cJSON_GetObjectItem(peer, "sdu_len");
                if (sdu) {
                    frame[n++] = (uint8_t)sdu->valueint;
                    frame[n++] = (uint8_t)(sdu->valueint >> 8);
                }
                int payload = cJSON_GetObjectItem(peer, "payload_len")->valueint;
                for (int k = 0; k < payload; k++) frame[n++] = next_byte++;
                bool was_closed = coc.closed != PDSH_COC_OK;
                pdsh_coc_close_t r = pdsh_ss_coc_kframe(&coc, frame, n);
                if (!was_closed && r != PDSH_COC_OK) closed = pdsh_coc_close_name(r);
            } else {
                static uint8_t out[70000];
                uint8_t returned = 0;
                size_t len = pdsh_ss_coc_consume(&coc, out, sizeof(out), &returned);
                credits = returned;
                if (len) cJSON_AddItemToArray(delivered, cJSON_CreateNumber((double)len));
            }
            /* Invariant at every instant: peer credits + held K-frames <= buffers. */
            CHECK(coc.closed || coc.peer_credits + coc.held <= coc.buffers, "%s step %d: invariant", name, i);
            const cJSON *want_close = cJSON_GetObjectItem(expect, "close");
            CHECK(credits == cJSON_GetObjectItem(expect, "credits")->valueint, "%s step %d: credits %d", name, i, credits);
            CHECK(cJSON_IsNull(want_close) ? closed == NULL : closed && !strcmp(closed, want_close->valuestring),
                  "%s step %d: close %s", name, i, closed ? closed : "null");
            CHECK(cJSON_Compare(delivered, cJSON_GetObjectItem(expect, "delivered"), true), "%s step %d: delivered", name, i);
            cJSON_Delete(delivered);
            i++;
        }
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    return rows;
}

/* Delivered SDU bytes are exactly the K-frame payloads in order. */
static void data_integrity(void) {
    static pdsh_ss_coc_t coc;
    CHECK(pdsh_ss_coc_init(&coc, 512, 247, 3), "init");
    uint8_t frame[247], out[512];
    for (int round = 0; round < 50; round++) {
        size_t sdu = 1 + (size_t)(round * 37) % 512, sent = 0;
        uint8_t v = (uint8_t)round;
        while (sent < sdu) {
            size_t n = 0;
            if (!sent) frame[n++] = (uint8_t)sdu, frame[n++] = (uint8_t)(sdu >> 8);
            size_t take = sdu - sent < 247 - n ? sdu - sent : 247 - n;
            for (size_t k = 0; k < take; k++) frame[n++] = (uint8_t)(v + sent + k);
            CHECK(pdsh_ss_coc_kframe(&coc, frame, n) == PDSH_COC_OK, "round %d", round);
            sent += take;
        }
        uint8_t credits;
        CHECK(pdsh_ss_coc_consume(&coc, out, sizeof(out), &credits) == sdu, "consume %d", round);
        for (size_t k = 0; k < sdu; k++) CHECK(out[k] == (uint8_t)(v + k), "byte %zu round %d", k, round);
    }
}

static void admission(void) {
    pdsh_ss_admission_t adm = {0};
    CHECK(pdsh_ss_admit(&adm, 1, 1000), "first CoC");
    CHECK(!pdsh_ss_admit(&adm, 1, 1000), "coc-second-concurrent-coc: second CoC refused");
    pdsh_ss_released(&adm, false, 2000);
    CHECK(!pdsh_ss_admit(&adm, 1, 3999), "2 s back-off after a failed handshake");
    CHECK(pdsh_ss_admit(&adm, 1, 4000), "admitted after back-off");
    pdsh_ss_released(&adm, false, 4000);
    CHECK(pdsh_ss_admit(&adm, 1, 6000), "second attempt");
    pdsh_ss_released(&adm, false, 6000);
    CHECK(!pdsh_ss_admit(&adm, 1, 9000), "3 failed handshakes on one LE link: refused");
    CHECK(!pdsh_ss_admit(&adm, 1, 100000), "still refused on that link");
    CHECK(pdsh_ss_admit(&adm, 2, 100000), "a new LE connection starts fresh");
    pdsh_ss_released(&adm, true, 100000);
    CHECK(pdsh_ss_admit(&adm, 2, 100000), "a completed handshake resets the count");
    printf("  coc-second-concurrent-coc (host) and admission limits PASS\n");
}

static void send_ownership(void) {
    pdsh_ss_tx_t tx = {0};
    bool caller_frees;
    CHECK(pdsh_ss_tx_can_send(&tx), "idle");
    pdsh_ss_tx_sent(&tx, PDSH_TX_RC_STALLED, &caller_frees);
    CHECK(!caller_frees && !pdsh_ss_tx_can_send(&tx) && tx.in_stack == 1, "stalled: stack owns, producer waits");
    /* coc-disconnect-during-queued-send: the stack frees the queued SDU in its
     * channel cleanup; we neither free it nor resend it. */
    pdsh_ss_tx_disconnected(&tx);
    CHECK(tx.in_stack == 0 && tx.broken && !pdsh_ss_tx_can_send(&tx), "after link loss");
    pdsh_ss_tx_t t2 = {0};
    pdsh_ss_tx_sent(&t2, PDSH_TX_RC_FAILED, &caller_frees);
    CHECK(!caller_frees && t2.broken, "partial send closes, never resent");
    pdsh_ss_tx_t t3 = {0};
    pdsh_ss_tx_sent(&t3, PDSH_TX_RC_NOT_TAKEN, &caller_frees);
    CHECK(caller_frees && t3.broken, "not taken: caller frees, stream closed");
    pdsh_ss_tx_t t4 = {0};
    pdsh_ss_tx_sent(&t4, PDSH_TX_RC_STALLED, &caller_frees);
    pdsh_ss_tx_unstalled(&t4, 0);
    CHECK(pdsh_ss_tx_can_send(&t4) && t4.in_stack == 0, "unstalled");
    printf("  coc-disconnect-during-queued-send (host) and send ownership PASS\n");
}

static uint64_t clock_ms = 1000;
static bool rng(uint8_t *out, size_t n) { return psa_generate_random(out, n) == PSA_SUCCESS; }

/* coc-client-hello-flood-with-reconnect (host): open, ClientHello, drop,
 * repeated; every session is freed (LeakSanitizer checks at exit) and the
 * admission back-off bounds the rate. */
static void flood(void) {
    fake_nvs_reset();
    CHECK(pdsh_identity_init(), "identity");
    static uint8_t cert[1024];
    size_t len = 0;
    CHECK(pdsh_cert_build(pdsh_identity_key(), true, cert, sizeof(cert), &len), "cert");
    pdsh_ss_server_cfg_t cfg = {cert, len, pdsh_identity_key(), &pdsh_ss_timers_v2, rng};
    pdsh_ss_admission_t adm = {0};
    int admitted = 0, refused = 0;
    uint8_t hello[300] = {0x16, 0x03, 0x01, 0x01, 0x20, 0x01};
    for (int i = 0; i < 600; i++) {
        clock_ms += 500;
        uint16_t link = (uint16_t)(1 + i / 10); /* reconnect every 10 attempts */
        if (!pdsh_ss_admit(&adm, link, clock_ms)) {
            refused++;
            continue;
        }
        admitted++;
        pdsh_ss_conn_t *c = pdsh_ss_conn_new(&cfg, clock_ms);
        CHECK(c, "conn");
        pdsh_ss_conn_rx(c, hello, sizeof(hello));
        pdsh_ss_conn_poll(c, clock_ms);
        uint8_t sink[512];
        while (pdsh_ss_conn_tx(c, sink, sizeof(sink))) {}
        pdsh_ss_conn_free(c); /* peer disconnects */
        pdsh_ss_released(&adm, false, clock_ms);
    }
    CHECK(admitted > 0 && refused > 0 && admitted <= 3 * 60, "admitted %d refused %d", admitted, refused);
    printf("  coc-client-hello-flood-with-reconnect (host): %d admitted, %d refused, no leak PASS\n", admitted, refused);
}

int main(int argc, char **argv) {
    CHECK(argc == 2, "usage: secure-coc <ble-secure-coc-cases.jsonl>");
    CHECK(psa_crypto_init() == PSA_SUCCESS, "psa");
    int rows = vectors(argv[1]);
    CHECK(rows == 10, "expected 10 coc vectors, got %d", rows);
    printf("secure CoC credit vectors: %d PASS (coc-credit-vectors, coc-send-beyond-credits, coc-zero-length-sdu, "
           "coc-sdu-over-mtu, coc-kframe-over-mps at host layer)\n", rows);
    data_integrity();
    admission();
    send_ownership();
    flood();
    return 0;
}

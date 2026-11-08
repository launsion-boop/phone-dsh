// SPDX-License-Identifier: MIT
/* secure-bridge: the real board end of secure-session-v2 as a host process for
 * cross-runtime conformance (Tests/PhoneDSHBLETests/BLESecureCrossRuntimeTests).
 *
 * Everything that decides is the firmware's own code: pdsh_identity.c (device
 * key, deterministic ECDSA), pdsh_secure_cert.c (certificate builder and the
 * §6.2 verifier), pdsh_enroll.c (console grammar, gesture classifier, board
 * record), pdsh_task_store.c (task store v2), and pdsh_secure_session.c (the
 * §5 CoC receive path, the TLS 1.3 server profile on mbedTLS, readiness and
 * request processing). Only the transport below the CoC (an honest L2CAP
 * sender with credit flow control, mirroring main.c's secure_task loop), the
 * NVS flash (test_secure_support.c) and the clock are substituted.
 *
 * Protocol: one command line on stdin, exactly one response line on stdout.
 *   boot                     -> ok <device fp>          (identity, record, store from fake NVS)
 *   console <line>           -> ok <board line>|<board line>...
 *   hold <ms>                -> ok <board line>|...      (one physical hold through the classifier)
 *   advance <ms>             -> ok                       (board monotonic clock; enrollment deadlines)
 *   submit <json>            -> ok | fail                (local task producer)
 *   result <id>              -> ok <slot json|null>      (the stored slot, owner included)
 *   open                     -> ok <coc> | refused       (CoC accept: coc init + TLS server)
 *   rx <coc> <hex>           -> <pump>                   (bytes from the phone's CoC)
 *   poll <coc>               -> <pump>
 *   eof <coc>                -> <pump>                   (phone closed the CoC)
 *   close                    -> ok                       (free the connection)
 * A <coc> other than the current one is a disconnected channel: its bytes are
 * dropped and the pump reports it closed ("stale").
 *   pump response: <handshake|open|closed> <alert> <reason> <coc close or -> <tx hex or ->
 */
#include "mbedtls/ssl.h"
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

#define MTU 512
#define MPS 247
#define RX_KFRAMES 3

static uint64_t clock_ms = 1000000;
static uint64_t now_ms(void) { return clock_ms; }
static char lines[2048];
static size_t lines_len;
static void board_line(const char *line) {
    size_t n = strlen(line);
    if (lines_len + n + 2 >= sizeof(lines)) return;
    if (lines_len) lines[lines_len++] = '|';
    memcpy(lines + lines_len, line, n);
    lines_len += n;
    lines[lines_len] = 0;
}
static bool revoked_flag;
static void on_revoked(void) { revoked_flag = true; }
static pdsh_enroll_ops_t ops = {now_ms, pdsh_entropy_random, true, true, board_line,
                                pdsh_identity_probe, pdsh_identity_reset, on_revoked};

static nvs_handle_t open_ns(const char *name) {
    nvs_handle_t h;
    CHECK(nvs_open(name, NVS_READWRITE, &h) == ESP_OK, "open %s", name);
    return h;
}

/* ---- the board's connection (main.c secure_task state) ---- */
static uint8_t cert[PDSH_CERT_MAX_DER];
static size_t cert_len;
static pdsh_ss_server_cfg_t cfg;
static pdsh_ss_coc_t coc;
static pdsh_ss_conn_t *conn;
static bool chan_open, peer_eof;
static pdsh_coc_close_t coc_closed;
static unsigned coc_id;
/* Honest L2CAP sender on the phone side: bytes the phone wrote and not yet
 * carried in K-frames; the SDU in progress. */
static uint8_t *pending;
static size_t pending_len, sdu_left;

static void hex_out(const uint8_t *p, size_t n) {
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        putchar(digits[p[i] >> 4]);
        putchar(digits[p[i] & 15]);
    }
}
static const char *state_name(pdsh_ss_conn_state_t s) {
    return s == PDSH_SS_CONN_HANDSHAKE ? "handshake" : s == PDSH_SS_CONN_OPEN ? "open" : "closed";
}

/* One K-frame of the honest sender, respecting the credits it holds. */
static bool send_kframe(void) {
    if (!pending_len || coc.peer_credits == 0 || coc_closed) return false;
    uint8_t frame[MPS];
    size_t n = 0;
    if (!sdu_left) {
        sdu_left = pending_len < MTU ? pending_len : MTU;
        frame[n++] = (uint8_t)sdu_left;
        frame[n++] = (uint8_t)(sdu_left >> 8);
    }
    size_t take = MPS - n < sdu_left ? MPS - n : sdu_left;
    memcpy(frame + n, pending, take);
    n += take;
    memmove(pending, pending + take, pending_len - take);
    pending_len -= take;
    sdu_left -= take;
    pdsh_coc_close_t r = pdsh_ss_coc_kframe(&coc, frame, n);
    if (r != PDSH_COC_OK) coc_closed = r;
    return true;
}

static void pump(void) {
    static uint8_t out[65536];
    size_t out_len = 0;
    pdsh_ss_conn_state_t st = PDSH_SS_CONN_CLOSED;
    for (int guard = 0; conn && guard < 100000; guard++) {
        bool progress = false;
        while (send_kframe()) progress = true;
        if (coc_closed) { /* the board disconnects the channel (§5) */
            chan_open = false;
            pending_len = 0;
        }
        size_t ready;
        while (chan_open && (ready = pdsh_ss_coc_ready(&coc)) && ready <= pdsh_ss_conn_rx_free(conn)) {
            uint8_t sdu[MTU];
            uint8_t credits;
            size_t n = pdsh_ss_coc_consume(&coc, sdu, sizeof(sdu), &credits);
            CHECK(n && pdsh_ss_conn_rx(conn, sdu, n), "consume");
            progress = true;
        }
        if (!chan_open || peer_eof) pdsh_ss_conn_eof(conn);
        st = pdsh_ss_conn_poll(conn, clock_ms);
        size_t n = pdsh_ss_conn_tx(conn, out + out_len, sizeof(out) - out_len);
        if (n) progress = true;
        out_len += n;
        CHECK(out_len < sizeof(out), "tx overflow");
        if (!progress) break;
    }
    if (conn) st = pdsh_ss_conn_poll(conn, clock_ms);
    printf("%s %d %s %s ", state_name(st), conn ? pdsh_ss_conn_alert(conn) : 0, conn ? pdsh_ss_conn_reason(conn) : "none",
           coc_closed ? pdsh_coc_close_name(coc_closed) : "-");
    if (out_len) hex_out(out, out_len);
    else putchar('-');
    putchar('\n');
}

/* A hold of the given length through the real gesture classifier (§3.3). */
static void hold(uint64_t ms) {
    bool levels[] = {false, false, true};
    for (int i = 0; i < 3; i++) {
        clock_ms += 60;
        pdsh_enroll_button(levels[i]);
        pdsh_enroll_tick();
    }
    for (uint64_t t = 0; t <= ms; t += 100) {
        clock_ms += 100;
        pdsh_enroll_button(true);
        pdsh_enroll_tick();
    }
    for (int i = 0; i < 2; i++) {
        clock_ms += 60;
        pdsh_enroll_button(false);
        pdsh_enroll_tick();
    }
}

static void close_conn(void) {
    pdsh_ss_conn_free(conn);
    conn = NULL;
    chan_open = peer_eof = false;
    free(pending);
    pending = NULL;
    pending_len = sdu_left = 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    CHECK(psa_crypto_init() == PSA_SUCCESS, "psa");
    fake_nvs_reset();
    char *line;
    while ((line = read_line(stdin))) {
        char *arg = strchr(line, ' ');
        if (arg) *arg++ = 0;
        lines_len = 0;
        lines[0] = 0;
        if (!strcmp(line, "boot")) {
            close_conn();
            char fp[65];
            CHECK(pdsh_identity_init() && pdsh_identity_probe(fp) == PDSH_IDENTITY_OK, "identity");
            CHECK(pdsh_cert_build(pdsh_identity_key(), true, cert, sizeof(cert), &cert_len), "device certificate");
            cfg = (pdsh_ss_server_cfg_t){cert, cert_len, pdsh_identity_key(), &pdsh_ss_timers_v2, pdsh_entropy_random};
            revoked_flag = false;
            CHECK(pdsh_enroll_init(&ops, open_ns("pdsh_enr")), "enroll init");
            pdsh_task_store_init(open_ns("pdsh_tools"));
            printf("ok %s\n", fp);
        } else if (!strcmp(line, "console") && arg) {
            pdsh_enroll_feed((const uint8_t *)arg, strlen(arg));
            pdsh_enroll_feed((const uint8_t *)"\n", 1);
            printf("ok %s\n", lines);
        } else if (!strcmp(line, "hold") && arg) {
            hold((uint64_t)strtoull(arg, NULL, 10));
            printf("ok %s\n", lines);
        } else if (!strcmp(line, "advance") && arg) {
            clock_ms += strtoull(arg, NULL, 10);
            pdsh_enroll_tick();
            printf("ok %s\n", lines);
        } else if (!strcmp(line, "submit") && arg) {
            puts(pdsh_task_store_submit(arg) ? "ok" : "fail");
        } else if (!strcmp(line, "result") && arg) {
            cJSON *view = pdsh_task_store_view(), *found = NULL, *slot;
            cJSON_ArrayForEach(slot, view) {
                const cJSON *id = cJSON_GetObjectItem(cJSON_GetObjectItem(slot, "task"), "id");
                if (cJSON_IsString(id) && !strcmp(id->valuestring, arg)) found = slot;
            }
            char *text = found ? cJSON_PrintUnformatted(found) : NULL;
            printf("ok %s\n", text ? text : "null");
            free(text);
            cJSON_Delete(view);
        } else if (!strcmp(line, "open")) {
            close_conn();
            coc_closed = PDSH_COC_OK;
            CHECK(pdsh_ss_coc_init(&coc, MTU, MPS, RX_KFRAMES), "coc init");
            conn = pdsh_ss_conn_new(&cfg, clock_ms);
            chan_open = conn != NULL;
            if (conn) printf("ok %u\n", ++coc_id);
            else puts("refused");
        } else if ((!strcmp(line, "rx") || !strcmp(line, "poll") || !strcmp(line, "eof")) && arg &&
                   (unsigned)strtoul(arg, NULL, 10) != coc_id) {
            puts("closed 0 stale - -");
        } else if (!strcmp(line, "rx") && arg && strchr(arg, ' ')) {
            arg = strchr(arg, ' ') + 1;
            size_t n = strlen(arg) / 2;
            uint8_t *grown = realloc(pending, pending_len + n + 1);
            CHECK(grown, "memory");
            pending = grown;
            if (chan_open) pending_len += hex_bytes(arg, pending + pending_len, n);
            pump();
        } else if (!strcmp(line, "poll") && arg) {
            pump();
        } else if (!strcmp(line, "eof") && arg) {
            peer_eof = true;
            pump();
        } else if (!strcmp(line, "close")) {
            close_conn();
            puts("ok");
        } else {
            printf("error unknown command %s\n", line);
        }
        free(line);
    }
    close_conn();
    return 0;
}

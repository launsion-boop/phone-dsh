// SPDX-License-Identifier: MIT
#include "pdsh_enroll.h"
#include "cJSON.h"
#include "pdsh_secure_msg.h"
#include "pdsh_task_validate.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
static SemaphoreHandle_t enroll_mutex;
void pdsh_enroll_lock(void) {
    if (enroll_mutex) xSemaphoreTakeRecursive(enroll_mutex, portMAX_DELAY);
}
void pdsh_enroll_unlock(void) {
    if (enroll_mutex) xSemaphoreGiveRecursive(enroll_mutex);
}
#else
void pdsh_enroll_lock(void) {}
void pdsh_enroll_unlock(void) {}
#endif

#define PREFIX "pdsh-enroll"
#define RPREFIX "pdsh-enroll-r"
#define RECORD_KEY "rec_v1"
#define RECORD_MAX 512

typedef enum { CTX_IDLE, CTX_BEGUN, CTX_STAGED, CTX_PRESS } ctx_t;
typedef enum { ACT_COMMIT, ACT_REVOKE, ACT_RESET } action_t;

static struct {
    const pdsh_enroll_ops_t *ops;
    nvs_handle_t nvs;
    pdsh_enroll_durable_t durable;
    ctx_t ctx;
    char ctx_eid[33], ctx_phone[65];
    action_t action;
    uint64_t ctx_deadline, press_deadline, press_written;
    bool ram_revoked;
    /* console line assembly */
    uint8_t line[PDSH_ENROLL_LINE_MAX + 2];
    size_t line_len, line_total;
    /* button debounce */
    bool raw, stable, consumed;
    uint64_t raw_since;
} E;

/* ---------------- grammar ---------------- */

static const char *const host_verbs[] = {"status", "begin", "phone", "commit", "abort", "revoke", "identity-reset"};
static const char *const host_fields[][3] = {
    {NULL}, {NULL}, {"eid", "phone", NULL}, {"eid", "device", "phone"}, {"eid", NULL}, {"eid", "device", "phone"}, {NULL}};
static const char *const resp_verbs[] = {"status", "begun", "staged", "press", "committed",
                                         "aborted", "revoked", "reset", "error"};
static const char *const resp_fields[][6] = {
    {"state", "ctx", "device", "phone", "eid", "rev"},
    {"eid", "device"},
    {"eid", "device", "phone", "token"},
    {"eid", "action", "timeout_s"},
    {"eid", "device", "phone", "rev"},
    {"eid"},
    {"eid", "device", "phone", "rev"},
    {"device"},
    {"code", "cmd"}};
static const char *const error_codes[] = {"syntax", "busy", "occupied", "no_session", "state", "eid_mismatch",
                                          "value_mismatch", "same_key", "timeout", "storage",
                                          "button_unavailable", "key_lost", "key_unavailable", "record_corrupt"};
static const char *const state_names[] = {"none", "committed", "revoked", "key_lost", "key_unavailable",
                                          "record_corrupt"};
static const char *const ctx_names[] = {"idle", "begun", "staged", "press"};
static const char *const action_names[] = {"commit", "revoke", "identity-reset"};

static int index_of(const char *s, size_t n, const char *const *list, size_t count) {
    for (size_t i = 0; i < count; i++)
        if (strlen(list[i]) == n && !memcmp(list[i], s, n)) return (int)i;
    return -1;
}
#define COUNT(a) (sizeof(a) / sizeof((a)[0]))
static size_t field_count(const char *const *names, size_t max) {
    size_t n = 0;
    while (n < max && names[n]) n++;
    return n;
}

/* Splits on single spaces; empty tokens make the line invalid. */
static bool tokens(const char *text, size_t n, pdsh_enroll_line_t *out, size_t skip,
                   const char *const *names, size_t count) {
    size_t pos = skip, field = 0;
    while (pos < n || field < count) {
        if (field == count) return false; /* extra field */
        if (pos >= n) return false;       /* missing field */
        const char *start = text + pos, *space = memchr(start, ' ', n - pos);
        size_t len = space ? (size_t)(space - start) : n - pos;
        const char *eq = memchr(start, '=', len);
        size_t name_len = eq ? (size_t)(eq - start) : 0;
        if (!eq || strlen(names[field]) != name_len || memcmp(start, names[field], name_len)) return false;
        size_t value_len = len - name_len - 1;
        if (!value_len || value_len >= sizeof(out->value[0])) return false;
        strcpy(out->name[field], names[field]);
        memcpy(out->value[field], eq + 1, value_len);
        out->value[field][value_len] = 0;
        field++;
        pos += len;
        if (space) {
            pos++;
            if (pos >= n) return false; /* trailing space */
        }
    }
    out->fields = (int)field;
    return true;
}
static bool printable(const uint8_t *line, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (line[i] < 0x20 || line[i] > 0x7e) return false;
    return true;
}
static void classify(const uint8_t *line, size_t n, const char *prefix, const char *const *verbs, size_t nverbs,
                     pdsh_enroll_line_t *out) {
    memset(out, 0, sizeof(*out));
    strcpy(out->echo, "-");
    size_t plen = strlen(prefix);
    const uint8_t *space = memchr(line, ' ', n);
    size_t first = space ? (size_t)(space - line) : n;
    out->addressed = first == plen && !memcmp(line, prefix, plen);
    if (!out->addressed || n <= plen + 1) return;
    const uint8_t *verb = line + plen + 1, *end = memchr(verb, ' ', n - plen - 1);
    size_t vlen = end ? (size_t)(end - verb) : n - plen - 1;
    int v = index_of((const char *)verb, vlen, verbs, nverbs);
    if (v >= 0) {
        strcpy(out->echo, verbs[v]);
        strcpy(out->verb, verbs[v]);
    }
}

void pdsh_enroll_parse_command(const uint8_t *line, size_t n, pdsh_enroll_line_t *out) {
    if (n && line[n - 1] == '\r') n--; /* one CR before LF */
    classify(line, n, PREFIX, host_verbs, COUNT(host_verbs), out);
    if (!out->addressed || !out->verb[0] || n > PDSH_ENROLL_LINE_MAX || !printable(line, n)) return;
    int v = index_of(out->verb, strlen(out->verb), host_verbs, COUNT(host_verbs));
    size_t skip = strlen(PREFIX) + 1 + strlen(out->verb);
    size_t want = field_count(host_fields[v], 3);
    if (n > skip && line[skip] != ' ') return;
    if (want == 0) {
        out->valid = n == skip;
        return;
    }
    if (n <= skip + 1 || !tokens((const char *)line, n, out, skip + 1, host_fields[v], want)) return;
    for (int i = 0; i < out->fields; i++) {
        size_t len = !strcmp(out->name[i], "eid") ? 32 : 64;
        if (!pdsh_lower_hex(out->value[i], len)) return;
    }
    out->valid = true;
}

static bool decimal_u32(const char *s) {
    size_t n = strlen(s);
    if (!n || n > 10 || (n > 1 && s[0] == '0')) return false;
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + (uint64_t)(s[i] - '0');
    }
    return v <= 0xffffffffu;
}
static const char *field(const pdsh_enroll_line_t *l, const char *name) {
    for (int i = 0; i < l->fields; i++)
        if (!strcmp(l->name[i], name)) return l->value[i];
    return NULL;
}
static bool hex_or_dash(const char *v, size_t len, bool dash) { return dash ? !strcmp(v, "-") : pdsh_lower_hex(v, len); }

void pdsh_enroll_parse_response(const uint8_t *line, size_t n, pdsh_enroll_line_t *out) {
    classify(line, n, RPREFIX, resp_verbs, COUNT(resp_verbs), out);
    if (!out->addressed || !out->verb[0] || n > PDSH_ENROLL_LINE_MAX || !printable(line, n)) return;
    int v = index_of(out->verb, strlen(out->verb), resp_verbs, COUNT(resp_verbs));
    size_t skip = strlen(RPREFIX) + 1 + strlen(out->verb);
    if (n <= skip + 1 || line[skip] != ' ' ||
        !tokens((const char *)line, n, out, skip + 1, resp_fields[v], field_count(resp_fields[v], 6)))
        return;
    const char *eid = field(out, "eid"), *device = field(out, "device"), *phone = field(out, "phone"),
               *rev = field(out, "rev");
    bool ok = true;
    if (!strcmp(out->verb, "status")) {
        int st = index_of(field(out, "state"), strlen(field(out, "state")), state_names, COUNT(state_names));
        ok = st >= 0 && index_of(field(out, "ctx"), strlen(field(out, "ctx")), ctx_names, COUNT(ctx_names)) >= 0;
        bool record = st == PDSH_ENR_COMMITTED || st == PDSH_ENR_REVOKED;
        bool no_key = st == PDSH_ENR_KEY_LOST || st == PDSH_ENR_KEY_UNAVAILABLE;
        ok = ok && hex_or_dash(device, 64, no_key) && hex_or_dash(phone, 64, !record) &&
             hex_or_dash(eid, 32, !record) && decimal_u32(rev);
    } else if (!strcmp(out->verb, "press")) {
        const char *action = field(out, "action");
        int a = index_of(action, strlen(action), action_names, COUNT(action_names));
        ok = a >= 0 && hex_or_dash(eid, 32, a == ACT_RESET) && !strcmp(field(out, "timeout_s"), "30");
    } else if (!strcmp(out->verb, "error")) {
        const char *code = field(out, "code"), *cmd = field(out, "cmd");
        ok = index_of(code, strlen(code), error_codes, COUNT(error_codes)) >= 0 &&
             (!strcmp(cmd, "-") || index_of(cmd, strlen(cmd), host_verbs, COUNT(host_verbs)) >= 0);
    } else {
        ok = (!eid || pdsh_lower_hex(eid, 32)) && (!device || pdsh_lower_hex(device, 64)) &&
             (!phone || pdsh_lower_hex(phone, 64)) && (!rev || decimal_u32(rev));
        const char *token = field(out, "token");
        if (ok && token) {
            char want[128];
            snprintf(want, sizeof(want), "pdsh-board-v1:%s:%s", device, eid);
            ok = !strcmp(token, want);
        }
    }
    out->valid = ok;
}

size_t pdsh_enroll_format(const pdsh_enroll_line_t *line, char *out, size_t cap) {
    int n = snprintf(out, cap, "%s %s", RPREFIX, line->verb);
    for (int i = 0; i < line->fields && n > 0 && (size_t)n < cap; i++)
        n += snprintf(out + n, cap - (size_t)n, " %s=%s", line->name[i], line->value[i]);
    return n > 0 && (size_t)n < cap ? (size_t)n : 0;
}

/* ---------------- responses ---------------- */

static void emit(const char *verb, int count, const char *const *values) {
    pdsh_enroll_line_t l;
    memset(&l, 0, sizeof(l));
    strcpy(l.verb, verb);
    int v = index_of(verb, strlen(verb), resp_verbs, COUNT(resp_verbs));
    for (int i = 0; i < count; i++) {
        strcpy(l.name[i], resp_fields[v][i]);
        snprintf(l.value[i], sizeof(l.value[i]), "%s", values[i]);
    }
    l.fields = count;
    char text[PDSH_ENROLL_LINE_MAX + 1];
    size_t n = pdsh_enroll_format(&l, text, sizeof(text));
    pdsh_enroll_line_t check;
    pdsh_enroll_parse_response((const uint8_t *)text, n, &check);
    /* The board never prints a pdsh-enroll-r line outside the grammar. */
    if (n && check.valid && E.ops && E.ops->write_line) E.ops->write_line(text);
}
static void error(const char *code, const char *cmd) {
    const char *v[] = {code, cmd};
    emit("error", 2, v);
}
static void abort_ctx(void) {
    E.ctx = CTX_IDLE;
    E.ctx_eid[0] = E.ctx_phone[0] = 0;
}

/* ---------------- durable record ---------------- */

static bool record_parse(const char *text, pdsh_enroll_durable_t *rec, const char *device) {
    cJSON *root = cJSON_ParseWithOpts(text, NULL, true);
    bool ok = root && cJSON_IsObject(root) && pdsh_task_unique_keys(root) && cJSON_GetArraySize(root) == 7;
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(root, "v"), *rv = cJSON_GetObjectItemCaseSensitive(root, "rev");
    const char *side = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "side"));
    const char *state = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "state"));
    const char *dev = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "device"));
    const char *phone = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "phone"));
    const char *eid = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "eid"));
    ok = ok && cJSON_IsNumber(v) && v->valuedouble == 1 && side && !strcmp(side, "board") && state &&
         (!strcmp(state, "committed") || !strcmp(state, "revoked")) && pdsh_device_id_valid(dev) &&
         pdsh_phone_id_valid(phone) && pdsh_lower_hex(eid, 32) && cJSON_IsNumber(rv) && rv->valuedouble >= 1 &&
         rv->valuedouble <= 4294967295.0 && rv->valuedouble == (double)(uint32_t)rv->valuedouble;
    if (ok && device) ok = !strcmp(dev + 4, device);
    if (ok) {
        rec->state = !strcmp(state, "committed") ? PDSH_ENR_COMMITTED : PDSH_ENR_REVOKED;
        snprintf(rec->device, sizeof(rec->device), "%s", dev + 4);
        snprintf(rec->phone, sizeof(rec->phone), "%s", phone + 6);
        snprintf(rec->eid, sizeof(rec->eid), "%s", eid);
        rec->rev = (uint32_t)rv->valuedouble;
    }
    cJSON_Delete(root);
    return ok;
}
/* Returns ESP_OK (rec filled), ESP_ERR_NVS_NOT_FOUND, or ESP_FAIL (corrupt). */
static esp_err_t record_read(pdsh_enroll_durable_t *rec, const char *device) {
    char buffer[RECORD_MAX];
    size_t n = sizeof(buffer);
    esp_err_t err = nvs_get_blob(E.nvs, RECORD_KEY, buffer, &n);
    if (err == ESP_ERR_NVS_NOT_FOUND) return err;
    if (err != ESP_OK || n < 2 || buffer[n - 1] != 0 || strlen(buffer) != n - 1 || !pdsh_task_json_no_nul(buffer))
        return ESP_FAIL;
    return record_parse(buffer, rec, device) ? ESP_OK : ESP_FAIL;
}
static bool record_write(pdsh_enroll_state_t state, const char *device, const char *phone, const char *eid,
                         uint32_t rev) {
    char text[RECORD_MAX];
    int n = snprintf(text, sizeof(text),
                     "{\"v\":1,\"side\":\"board\",\"state\":\"%s\",\"device\":\"ble:%s\",\"phone\":\"phone:%s\","
                     "\"eid\":\"%s\",\"rev\":%" PRIu32 "}",
                     state == PDSH_ENR_COMMITTED ? "committed" : "revoked", device, phone, eid, rev);
    if (n <= 0 || (size_t)n >= sizeof(text)) return false;
    if (nvs_set_blob(E.nvs, RECORD_KEY, text, (size_t)n + 1) != ESP_OK || nvs_commit(E.nvs) != ESP_OK) return false;
    pdsh_enroll_durable_t back;
    memset(&back, 0, sizeof(back));
    return record_read(&back, device) == ESP_OK && back.state == state && !strcmp(back.device, device) &&
           !strcmp(back.phone, phone) && !strcmp(back.eid, eid) && back.rev == rev;
}
/* §4.2 boot classification from the identity probe and rec_v1. */
static void classify_durable(void) {
    pdsh_enroll_durable_t d;
    memset(&d, 0, sizeof(d));
    char fp[65] = {0};
    pdsh_identity_status_t id = E.ops->identity_probe ? E.ops->identity_probe(fp) : PDSH_IDENTITY_UNAVAILABLE;
    if (id == PDSH_IDENTITY_OK) {
        snprintf(d.device, sizeof(d.device), "%s", fp);
        esp_err_t err = record_read(&d, fp);
        if (err == ESP_ERR_NVS_NOT_FOUND) d.state = PDSH_ENR_NONE;
        else if (err != ESP_OK) {
            memset(&d, 0, sizeof(d));
            snprintf(d.device, sizeof(d.device), "%s", fp);
            d.state = PDSH_ENR_RECORD_CORRUPT;
        }
    } else {
        pdsh_enroll_durable_t old;
        memset(&old, 0, sizeof(old));
        if (id == PDSH_IDENTITY_KEY_LOST && record_read(&old, NULL) == ESP_OK) {
            /* The lost record stays visible for diagnosis; it grants nothing. */
            snprintf(d.phone, sizeof(d.phone), "%s", old.phone);
            snprintf(d.eid, sizeof(d.eid), "%s", old.eid);
            d.rev = old.rev;
        }
        d.state = id == PDSH_IDENTITY_KEY_LOST ? PDSH_ENR_KEY_LOST : PDSH_ENR_KEY_UNAVAILABLE;
    }
    E.durable = d;
}

bool pdsh_enroll_init(const pdsh_enroll_ops_t *ops, nvs_handle_t record_namespace) {
#ifdef ESP_PLATFORM
    if (!enroll_mutex) enroll_mutex = xSemaphoreCreateRecursiveMutex();
#endif
    pdsh_enroll_lock();
    memset(&E, 0, sizeof(E));
    E.ops = ops;
    E.nvs = record_namespace;
    classify_durable();
    pdsh_enroll_unlock();
    return true;
}
void pdsh_enroll_durable(pdsh_enroll_durable_t *out) {
    pdsh_enroll_lock();
    *out = E.durable;
    pdsh_enroll_unlock();
}
const char *pdsh_enroll_ctx_name(void) { return ctx_names[E.ctx]; }
bool pdsh_enroll_session_record(pdsh_enroll_durable_t *out) {
    pdsh_enroll_lock();
    bool ok = E.ops && E.durable.state == PDSH_ENR_COMMITTED && !E.ram_revoked;
    if (ok && out) *out = E.durable;
    pdsh_enroll_unlock();
    return ok;
}

/* ---------------- state machine ---------------- */

static uint64_t now(void) { return E.ops->now_ms ? E.ops->now_ms() : 0; }
static void status_line(void) {
    char rev[11];
    snprintf(rev, sizeof(rev), "%" PRIu32, E.durable.rev);
    bool record = E.durable.state == PDSH_ENR_COMMITTED || E.durable.state == PDSH_ENR_REVOKED;
    bool no_key = E.durable.state == PDSH_ENR_KEY_LOST || E.durable.state == PDSH_ENR_KEY_UNAVAILABLE;
    const char *v[] = {state_names[E.durable.state], ctx_names[E.ctx], no_key ? "-" : E.durable.device,
                       record ? E.durable.phone : "-", record ? E.durable.eid : "-", rev};
    emit("status", 6, v);
}
static void begin_press(action_t action, const char *eid) {
    E.ctx = CTX_PRESS;
    E.action = action;
    const char *v[] = {eid, action_names[action], "30"};
    emit("press", 3, v);
    E.press_written = now();
    E.press_deadline = E.press_written + PDSH_ENROLL_PRESS_TIMEOUT_MS;
}

static void command(const pdsh_enroll_line_t *l) {
    const char *verb = l->echo;
    if (E.ctx == CTX_PRESS) { /* rule 1: any addressed line aborts the pending press */
        abort_ctx();
        error("busy", verb);
        return;
    }
    if (!l->valid) { /* rule 2 */
        error("syntax", verb);
        return;
    }
    if (!strcmp(verb, "status")) { /* rule 3 */
        status_line();
        return;
    }
    pdsh_enroll_state_t st = E.durable.state;
    if ((st == PDSH_ENR_KEY_LOST || st == PDSH_ENR_KEY_UNAVAILABLE || st == PDSH_ENR_RECORD_CORRUPT) &&
        strcmp(verb, "identity-reset")) { /* rule 4 */
        abort_ctx();
        error(state_names[st], verb);
        return;
    }
    const char *eid = field(l, "eid"), *phone = field(l, "phone"), *device = field(l, "device");
    if (!strcmp(verb, "begin")) {
        if (E.ctx != CTX_IDLE) {
            abort_ctx();
            error("busy", verb);
        } else if (st == PDSH_ENR_COMMITTED) error("occupied", verb);
        else if (!E.ops->button_available) error("button_unavailable", verb);
        else {
            uint8_t raw[16];
            E.ops->random(raw, sizeof(raw));
            pdsh_hex_encode(raw, sizeof(raw), E.ctx_eid);
            E.ctx = CTX_BEGUN;
            E.ctx_deadline = now() + PDSH_ENROLL_CONTEXT_TIMEOUT_MS;
            const char *v[] = {E.ctx_eid, E.durable.device};
            emit("begun", 2, v);
        }
    } else if (!strcmp(verb, "phone")) {
        if (E.ctx == CTX_IDLE) error("no_session", verb);
        else if (E.ctx != CTX_BEGUN) abort_ctx(), error("state", verb);
        else if (strcmp(eid, E.ctx_eid)) abort_ctx(), error("eid_mismatch", verb);
        else if (!strcmp(phone, E.durable.device)) abort_ctx(), error("same_key", verb);
        else {
            snprintf(E.ctx_phone, sizeof(E.ctx_phone), "%s", phone);
            E.ctx = CTX_STAGED;
            char token[128];
            snprintf(token, sizeof(token), "pdsh-board-v1:%s:%s", E.durable.device, E.ctx_eid);
            const char *v[] = {E.ctx_eid, E.durable.device, E.ctx_phone, token};
            emit("staged", 4, v);
        }
    } else if (!strcmp(verb, "commit")) {
        if (E.ctx == CTX_IDLE) error("no_session", verb);
        else if (E.ctx != CTX_STAGED) abort_ctx(), error("state", verb);
        else if (strcmp(eid, E.ctx_eid)) abort_ctx(), error("eid_mismatch", verb);
        else if (strcmp(device, E.durable.device) || strcmp(phone, E.ctx_phone)) abort_ctx(), error("value_mismatch", verb);
        else begin_press(ACT_COMMIT, E.ctx_eid);
    } else if (!strcmp(verb, "abort")) {
        if (E.ctx == CTX_IDLE) error("no_session", verb);
        else if (strcmp(eid, E.ctx_eid)) abort_ctx(), error("eid_mismatch", verb);
        else {
            char aborted[33];
            snprintf(aborted, sizeof(aborted), "%s", E.ctx_eid);
            abort_ctx();
            const char *v[] = {aborted};
            emit("aborted", 1, v);
        }
    } else if (!strcmp(verb, "revoke")) {
        if (E.ctx != CTX_IDLE) abort_ctx(), error("busy", verb);
        else if (st != PDSH_ENR_COMMITTED) error("state", verb);
        else if (strcmp(eid, E.durable.eid) || strcmp(device, E.durable.device) || strcmp(phone, E.durable.phone))
            error("value_mismatch", verb);
        else {
            snprintf(E.ctx_eid, sizeof(E.ctx_eid), "%s", E.durable.eid);
            begin_press(ACT_REVOKE, E.ctx_eid);
        }
    } else if (!strcmp(verb, "identity-reset")) {
        if (E.ctx != CTX_IDLE) abort_ctx(), error("busy", verb);
        else if (st == PDSH_ENR_COMMITTED) error("occupied", verb);
        else if (!E.ops->button_available) error("button_unavailable", verb);
        else begin_press(ACT_RESET, "-");
    }
}

static void on_press(void) {
    action_t action = E.action;
    char eid[33], phone[65];
    snprintf(eid, sizeof(eid), "%s", E.ctx_eid);
    snprintf(phone, sizeof(phone), "%s", E.ctx_phone);
    abort_ctx();
    char rev[11];
    if (action == ACT_COMMIT) {
        uint32_t next = E.durable.rev + 1;
        if (next == 0 || !record_write(PDSH_ENR_COMMITTED, E.durable.device, phone, eid, next)) {
            classify_durable(); /* the host learns the durable truth from a later status */
            error("storage", "commit");
            return;
        }
        classify_durable();
        E.ram_revoked = false;
        snprintf(rev, sizeof(rev), "%" PRIu32, next);
        const char *v[] = {eid, E.durable.device, phone, rev};
        emit("committed", 4, v);
    } else if (action == ACT_REVOKE) {
        E.ram_revoked = true; /* closes live sessions before the durable write */
        if (E.ops->revoked) E.ops->revoked();
        pdsh_enroll_durable_t old = E.durable;
        uint32_t next = old.rev + 1;
        if (next == 0 || !record_write(PDSH_ENR_REVOKED, old.device, old.phone, old.eid, next)) {
            classify_durable(); /* the RAM flag stays set until reboot */
            error("storage", "revoke");
            return;
        }
        classify_durable();
        snprintf(rev, sizeof(rev), "%" PRIu32, next);
        const char *v[] = {old.eid, old.device, old.phone, rev};
        emit("revoked", 4, v);
    } else {
        char fp[65] = {0};
        if (!E.ops->identity_reset || !E.ops->identity_reset(fp)) {
            classify_durable();
            error("storage", "identity-reset");
            return;
        }
        E.ram_revoked = false;
        classify_durable();
        const char *v[] = {fp};
        emit("reset", 1, v);
    }
}

static void process_line(const uint8_t *line, size_t n, bool over_length) {
    pdsh_enroll_line_t l;
    pdsh_enroll_parse_command(line, n, &l);
    if (!l.addressed) return;
    if (over_length) l.valid = false;
    command(&l);
}

void pdsh_enroll_feed(const uint8_t *data, size_t n) {
    pdsh_enroll_lock();
    for (size_t i = 0; i < n && E.ops; i++) {
        if (data[i] == '\n') {
            process_line(E.line, E.line_len, E.line_total > E.line_len);
            E.line_len = E.line_total = 0;
            continue;
        }
        if (E.line_len < sizeof(E.line)) E.line[E.line_len++] = data[i];
        E.line_total++;
    }
    pdsh_enroll_unlock();
}

void pdsh_enroll_tick(void) {
    pdsh_enroll_lock();
    if (E.ops) {
        uint64_t t = now();
        if (E.ctx == CTX_PRESS && t >= E.press_deadline) {
            action_t action = E.action;
            abort_ctx();
            error("timeout", action_names[action]);
        } else if ((E.ctx == CTX_BEGUN || E.ctx == CTX_STAGED) && t >= E.ctx_deadline) {
            abort_ctx();
            error("timeout", "-");
        }
    }
    pdsh_enroll_unlock();
}

bool pdsh_enroll_button(bool level) {
    pdsh_enroll_lock();
    bool owned = false;
    if (E.ops) {
        uint64_t t = now();
        if (level != E.raw) {
            E.raw = level;
            E.raw_since = t;
        }
        bool edge = false;
        if (E.raw != E.stable && t - E.raw_since >= PDSH_ENROLL_DEBOUNCE_MS) {
            E.stable = E.raw;
            edge = E.stable;
        }
        if (!E.stable) E.consumed = false;
        if (E.ctx == CTX_PRESS) {
            pdsh_enroll_tick();
            /* Only a press that began after the press line was written counts. */
            if (E.ctx == CTX_PRESS && edge && E.raw_since >= E.press_written) {
                E.consumed = true;
                on_press();
            }
            owned = true;
        }
        owned = owned || E.consumed;
    }
    pdsh_enroll_unlock();
    return owned;
}

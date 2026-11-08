// SPDX-License-Identifier: MIT
/* secure-enroll: drives the real pdsh_enroll.c console grammar and board state
 * machine with golden/ble-secure-enrollment-lines.jsonl and the side=board rows
 * of golden/ble-secure-enrollment-states.jsonl, and the real pdsh_identity.c
 * (§4.2 boot classification, identity-reset) against a fake NVS and the host
 * build of the PSA crypto core. Key generation for the state vectors is a
 * substituted seam (the vectors name the new fingerprints); every trust
 * decision runs in the real code. */
#include "../esp32-reference/main/pdsh_identity.c"
#include "pdsh_enroll.h"
#include "pdsh_secure_msg.h"
#include "test_secure_support.h"
#include <stdlib.h>
#include <string.h>

/* ---------------- seams ---------------- */
static uint64_t clock_ms;
static char outputs[8][512];
static int output_count, revoked_calls;
static char fake_device[65], new_keys[4][65], eids[4][33];
static int new_key_count, new_key_next, eid_count, eid_next;
static pdsh_identity_status_t fake_status;

static uint64_t now_ms(void) { return clock_ms; }
static void write_line(const char *line) {
    CHECK(output_count < 8, "too many outputs");
    snprintf(outputs[output_count++], sizeof(outputs[0]), "%s", line);
}
static void random_eid(uint8_t *out, size_t n) {
    CHECK(n == 16 && eid_next < eid_count, "eid supply");
    pdsh_hex_decode(eids[eid_next++], out, 16);
}
static pdsh_identity_status_t fake_probe(char fp[65]) {
    if (fake_status == PDSH_IDENTITY_OK) snprintf(fp, 65, "%s", fake_device);
    return fake_status;
}
static bool fake_reset(char fp[65]) {
    if (new_key_next >= new_key_count) return false;
    nvs_handle_t h;
    nvs_open("pdsh_enr", NVS_READWRITE, &h);
    nvs_erase_key(h, "rec_v1");
    if (nvs_commit(h) != ESP_OK) return false;
    snprintf(fake_device, sizeof(fake_device), "%s", new_keys[new_key_next++]);
    fake_status = PDSH_IDENTITY_OK;
    snprintf(fp, 65, "%s", fake_device);
    return true;
}
static void on_revoked(void) { revoked_calls++; }
static pdsh_enroll_ops_t ops = {now_ms, random_eid, true, write_line, fake_probe, fake_reset, on_revoked};
static nvs_handle_t enr_ns(void) {
    nvs_handle_t h;
    CHECK(nvs_open("pdsh_enr", NVS_READWRITE, &h) == ESP_OK, "open");
    return h;
}
static void feed_line(const char *text) {
    output_count = 0;
    pdsh_enroll_feed((const uint8_t *)text, strlen(text));
    pdsh_enroll_feed((const uint8_t *)"\n", 1);
}
static void press_button(void) {
    /* A debounced release->press edge strictly after the press line. */
    clock_ms += 10;
    pdsh_enroll_button(false);
    clock_ms += 60;
    pdsh_enroll_button(false);
    clock_ms += 10;
    pdsh_enroll_button(true);
    clock_ms += 60;
    pdsh_enroll_button(true);
    clock_ms += 60;
    pdsh_enroll_button(false);
    clock_ms += 60;
    pdsh_enroll_button(false);
}

/* ---------------- lines ---------------- */
static int lines(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0;
    char *text;
    while ((text = read_line(f))) {
        cJSON *row = cJSON_Parse(text);
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        const char *dir = cJSON_GetObjectItem(row, "dir")->valuestring;
        uint8_t bytes[1024];
        size_t n = hex_bytes(cJSON_GetObjectItem(row, "bytes_hex")->valuestring, bytes, sizeof(bytes));
        CHECK(n && bytes[n - 1] == '\n', "%s: LF", name);
        n--;
        bool addressed = cJSON_IsTrue(cJSON_GetObjectItem(row, "addressed"));
        bool valid = cJSON_IsTrue(cJSON_GetObjectItem(row, "valid"));
        const cJSON *echo = cJSON_GetObjectItem(row, "echo"), *parsed = cJSON_GetObjectItem(row, "parsed");
        pdsh_enroll_line_t l;
        bool host = !strcmp(dir, "host");
        if (host) pdsh_enroll_parse_command(bytes, n, &l);
        else pdsh_enroll_parse_response(bytes, n, &l);
        CHECK(l.addressed == addressed && l.valid == valid, "%s: addressed %d valid %d", name, l.addressed, l.valid);
        if (echo) CHECK(!strcmp(l.echo, echo->valuestring), "%s: echo %s", name, l.echo);
        if (parsed) {
            const cJSON *fields = cJSON_GetObjectItem(parsed, "fields");
            CHECK(!strcmp(l.verb, cJSON_GetObjectItem(parsed, "verb")->valuestring), "%s: verb", name);
            CHECK(l.fields == cJSON_GetArraySize(fields), "%s: field count", name);
            int i = 0;
            for (const cJSON *fv = fields->child; fv; fv = fv->next, i++)
                CHECK(!strcmp(l.name[i], fv->string) && !strcmp(l.value[i], fv->valuestring), "%s: field %d", name, i);
        }
        if (!host && valid) { /* printer: byte-exact */
            char out[512];
            size_t m = pdsh_enroll_format(&l, out, sizeof(out));
            CHECK(m == n && !memcmp(out, bytes, n), "%s: printer", name);
        }
        if (host && !valid) { /* the streaming console path gives the same answer */
            fake_nvs_reset();
            fake_status = PDSH_IDENTITY_OK;
            snprintf(fake_device, sizeof(fake_device), "9f884378e0c09834f2d27bb467eb005ee6cba0e2b66e0220b1b702e31f74473c");
            pdsh_enroll_init(&ops, enr_ns());
            output_count = 0;
            pdsh_enroll_feed(bytes, n + 1);
            if (!addressed) CHECK(output_count == 0, "%s: unaddressed got output", name);
            else {
                char want[64];
                snprintf(want, sizeof(want), "pdsh-enroll-r error code=syntax cmd=%s", l.echo);
                CHECK(output_count == 1 && !strcmp(outputs[0], want), "%s: console %s", name, outputs[0]);
            }
        }
        cJSON_Delete(row);
        free(text);
        rows++;
    }
    fclose(f);
    return rows;
}

/* ---------------- board state vectors ---------------- */
static const char *str_or_empty(const cJSON *v) { return cJSON_IsString(v) ? v->valuestring : ""; }
static const char *state_name(pdsh_enroll_state_t s) {
    static const char *const n[] = {"none", "committed", "revoked", "key_lost", "key_unavailable", "record_corrupt"};
    return n[s];
}
static void write_record(const char *state, const char *device, const char *phone, const char *eid, int rev) {
    char text[512];
    snprintf(text, sizeof(text),
             "{\"v\":1,\"side\":\"board\",\"state\":\"%s\",\"device\":\"ble:%s\",\"phone\":\"phone:%s\",\"eid\":\"%s\",\"rev\":%d}",
             state, device, phone, eid, rev);
    fake_nvs_put("pdsh_enr", "rec_v1", text, strlen(text) + 1);
}
static int states(const char *path, int *steps_out) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open");
    int rows = 0, steps = 0;
    char *text;
    while ((text = read_line(f))) {
        cJSON *row = cJSON_Parse(text);
        if (strcmp(cJSON_GetObjectItem(row, "side")->valuestring, "board")) {
            cJSON_Delete(row);
            free(text);
            continue;
        }
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        const cJSON *given = cJSON_GetObjectItem(row, "given");
        const char *gstate = cJSON_GetObjectItem(given, "state")->valuestring;
        fake_nvs_reset();
        clock_ms = 1000000;
        revoked_calls = 0;
        eid_count = eid_next = new_key_count = new_key_next = 0;
        const cJSON *item;
        cJSON_ArrayForEach(item, cJSON_GetObjectItem(given, "eids")) snprintf(eids[eid_count++], 33, "%s", item->valuestring);
        cJSON_ArrayForEach(item, cJSON_GetObjectItem(given, "new_keys")) snprintf(new_keys[new_key_count++], 65, "%s", item->valuestring);
        ops.button_available = !cJSON_IsFalse(cJSON_GetObjectItem(given, "button"));
        snprintf(fake_device, sizeof(fake_device), "%s", str_or_empty(cJSON_GetObjectItem(given, "device")));
        fake_status = PDSH_IDENTITY_OK;
        int rev = cJSON_GetObjectItem(given, "rev")->valueint;
        const char *phone = str_or_empty(cJSON_GetObjectItem(given, "phone")), *eid = str_or_empty(cJSON_GetObjectItem(given, "eid"));
        if (!strcmp(gstate, "committed") || !strcmp(gstate, "revoked")) write_record(gstate, fake_device, phone, eid, rev);
        else if (!strcmp(gstate, "key_lost")) {
            fake_status = PDSH_IDENTITY_KEY_LOST;
            write_record("committed", "0000000000000000000000000000000000000000000000000000000000000000", phone, eid, rev);
        } else if (!strcmp(gstate, "key_unavailable")) fake_status = PDSH_IDENTITY_UNAVAILABLE;
        else if (!strcmp(gstate, "record_corrupt")) fake_nvs_put("pdsh_enr", "rec_v1", "{\"v\":1,", 8);
        pdsh_enroll_init(&ops, enr_ns());
        int i = 0;
        cJSON_ArrayForEach(item, cJSON_GetObjectItem(row, "steps")) {
            const cJSON *line = cJSON_GetObjectItem(item, "line"), *event = cJSON_GetObjectItem(item, "event");
            const cJSON *out = cJSON_GetObjectItem(item, "out"), *durable = cJSON_GetObjectItem(item, "durable");
            const cJSON *authority = cJSON_GetObjectItem(item, "session_authority");
            clock_ms += 1000;
            output_count = 0;
            if (line) feed_line(line->valuestring);
            else {
                const char *e = event->valuestring;
                if (!strcmp(e, "press")) press_button();
                else if (!strcmp(e, "reboot")) pdsh_enroll_init(&ops, enr_ns());
                else if (!strcmp(e, "press_timeout")) clock_ms += PDSH_ENROLL_PRESS_TIMEOUT_MS, pdsh_enroll_tick();
                else if (!strcmp(e, "context_expired")) clock_ms += PDSH_ENROLL_CONTEXT_TIMEOUT_MS, pdsh_enroll_tick();
                else if (!strcmp(e, "fail_next_write")) fake_nvs_fail_next_commit();
                else CHECK(false, "%s: unknown event %s", name, e);
            }
            if (cJSON_IsNull(out)) CHECK(output_count == 0, "%s step %d: unexpected %s", name, i, outputs[0]);
            else CHECK(output_count == 1 && !strcmp(outputs[0], out->valuestring), "%s step %d: got [%s] want [%s]",
                       name, i, output_count ? outputs[0] : "", out->valuestring);
            pdsh_enroll_durable_t d;
            pdsh_enroll_durable(&d);
            CHECK(!strcmp(state_name(d.state), cJSON_GetObjectItem(durable, "state")->valuestring), "%s step %d: state %s",
                  name, i, state_name(d.state));
            CHECK(!strcmp(d.device, str_or_empty(cJSON_GetObjectItem(durable, "device"))), "%s step %d: device", name, i);
            CHECK(!strcmp(d.phone, str_or_empty(cJSON_GetObjectItem(durable, "phone"))), "%s step %d: phone", name, i);
            CHECK(!strcmp(d.eid, str_or_empty(cJSON_GetObjectItem(durable, "eid"))), "%s step %d: eid", name, i);
            CHECK((int)d.rev == cJSON_GetObjectItem(durable, "rev")->valueint, "%s step %d: rev %u", name, i, d.rev);
            if (authority)
                CHECK(pdsh_enroll_session_record(NULL) == cJSON_IsTrue(authority), "%s step %d: authority", name, i);
            i++;
            steps++;
        }
        if (strstr(name, "revoke-closes") || strstr(name, "revoke-storage")) CHECK(revoked_calls == 1, "%s: revoked hook", name);
        cJSON_Delete(row);
        free(text);
        rows++;
    }
    fclose(f);
    *steps_out = steps;
    return rows;
}

/* ---------------- real identity + enrollment ---------------- */
static void identity_reboot(void) {
    if (key_id) psa_destroy_key(key_id);
    key_id = 0;
    ready_flag = false;
    status = PDSH_IDENTITY_UNAVAILABLE;
    pdsh_identity_init();
}
static void fp_of_stored_priv(char fp[65]) {
    uint8_t priv[32], point[65];
    size_t n = sizeof(priv);
    CHECK(fake_nvs_get("pdsh_id", "priv", priv, &n) && n == 32, "priv stored");
    psa_key_attributes_t a = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&a, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&a, 256);
    psa_key_id_t k;
    CHECK(psa_import_key(&a, priv, 32, &k) == PSA_SUCCESS, "import");
    CHECK(psa_export_public_key(k, point, 65, &n) == PSA_SUCCESS && n == 65, "export");
    psa_destroy_key(k);
    CHECK(pdsh_fingerprint(point, fp), "fp");
}
static void real_random(uint8_t *out, size_t n) { CHECK(psa_generate_random(out, n) == PSA_SUCCESS, "rng"); }
static int identity_and_flow(void) {
    int checks = 0;
    char fp[65], again[65], stored[65];
    fake_nvs_reset();
    identity_reboot();
    CHECK(pdsh_identity_probe(fp) == PDSH_IDENTITY_OK, "first boot generates");
    fp_of_stored_priv(stored);
    CHECK(!strcmp(fp, stored), "fingerprint of the persisted key");
    int commits = fake_nvs_commits();
    identity_reboot();
    CHECK(pdsh_identity_probe(again) == PDSH_IDENTITY_OK && !strcmp(fp, again) && fake_nvs_commits() == commits,
          "reboot keeps the key without writes");
    checks += 3;

    /* Real enrollment with the real identity seams. */
    pdsh_enroll_ops_t real = {now_ms, real_random, true, write_line, pdsh_identity_probe, pdsh_identity_reset, on_revoked};
    clock_ms = 5000;
    pdsh_enroll_init(&real, enr_ns());
    feed_line("pdsh-enroll begin");
    char eid[33];
    CHECK(output_count == 1 && sscanf(outputs[0], "pdsh-enroll-r begun eid=%32s", eid) == 1, "begin");
    const char *phone = "9b6cc456bc66478c30edb378c40b490e13480ddad90e59dda9efd13e4337f03e";
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "pdsh-enroll phone eid=%s phone=%s", eid, phone);
    feed_line(cmd);
    /* A press already held before the prompt does not count. */
    pdsh_enroll_button(true);
    clock_ms += 100;
    pdsh_enroll_button(true);
    snprintf(cmd, sizeof(cmd), "pdsh-enroll commit eid=%s device=%s phone=%s", eid, fp, phone);
    feed_line(cmd);
    CHECK(output_count == 1 && strstr(outputs[0], "action=commit"), "press prompt");
    output_count = 0;
    clock_ms += 100;
    CHECK(pdsh_enroll_button(true), "owned while waiting");
    clock_ms += 100;
    pdsh_enroll_button(true);
    CHECK(output_count == 0, "held press ignored");
    clock_ms += 100;
    pdsh_enroll_button(false);
    clock_ms += 100;
    pdsh_enroll_button(false);
    press_button();
    CHECK(output_count == 1 && strstr(outputs[0], "pdsh-enroll-r committed") && strstr(outputs[0], "rev=1"), "%s", outputs[0]);
    CHECK(pdsh_enroll_session_record(NULL), "authority");
    checks += 5;
    /* Reboot: committed record survives, key unchanged. */
    identity_reboot();
    pdsh_enroll_init(&real, enr_ns());
    pdsh_enroll_durable_t d;
    pdsh_enroll_durable(&d);
    CHECK(d.state == PDSH_ENR_COMMITTED && !strcmp(d.device, fp) && !strcmp(d.phone, phone) && d.rev == 1, "durable");
    /* Key lost with a record: never regenerated. */
    nvs_handle_t h;
    nvs_open("pdsh_id", NVS_READWRITE, &h);
    nvs_erase_key(h, "priv");
    nvs_commit(h);
    identity_reboot();
    size_t n;
    CHECK(pdsh_identity_probe(again) == PDSH_IDENTITY_KEY_LOST && !fake_nvs_get("pdsh_id", "priv", NULL, &n), "key_lost");
    pdsh_enroll_init(&real, enr_ns());
    feed_line("pdsh-enroll status");
    CHECK(!strcmp(outputs[0], "pdsh-enroll-r status state=key_lost ctx=idle device=- phone=- eid=- rev=1"), "%s", outputs[0]);
    feed_line("pdsh-enroll identity-reset");
    output_count = 0;
    press_button();
    char fresh[65];
    CHECK(output_count == 1 && sscanf(outputs[0], "pdsh-enroll-r reset device=%64s", fresh) == 1 && strcmp(fresh, fp),
          "reset %s", outputs[0]);
    CHECK(!fake_nvs_get("pdsh_enr", "rec_v1", NULL, &n), "record erased");
    fp_of_stored_priv(stored);
    CHECK(!strcmp(stored, fresh), "new key persisted");
    checks += 5;
    /* Unreadable or wrong-length key: unavailable, nothing generated. */
    uint8_t short_key[16] = {1};
    fake_nvs_put("pdsh_id", "priv", short_key, sizeof(short_key));
    identity_reboot();
    CHECK(pdsh_identity_probe(again) == PDSH_IDENTITY_UNAVAILABLE, "wrong length");
    fake_nvs_unreadable("pdsh_id", "priv");
    identity_reboot();
    CHECK(pdsh_identity_probe(again) == PDSH_IDENTITY_UNAVAILABLE, "unreadable");
    checks += 2;
    return checks;
}

int main(int argc, char **argv) {
    CHECK(argc == 3, "usage: secure-enroll <enrollment-lines.jsonl> <enrollment-states.jsonl>");
    CHECK(psa_crypto_init() == PSA_SUCCESS, "psa");
    int line_rows = lines(argv[1]);
    int steps = 0, state_rows = states(argv[2], &steps);
    CHECK(line_rows == 46 && state_rows > 0, "rows %d %d", line_rows, state_rows);
    int checks = identity_and_flow();
    printf("secure enrollment line vectors: %d PASS; board state vectors: %d (%d steps) PASS; "
           "identity/enrollment flow: %d checks PASS\n",
           line_rows, state_rows, steps, checks);
    return 0;
}

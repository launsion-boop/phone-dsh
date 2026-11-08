// SPDX-License-Identifier: MIT
/* task-store-v2: drives the real pdsh_task_store.c with
 * golden/ble-secure-task-store-cases.jsonl (selection and migration) and the
 * secure ownership transitions of ble-secure-session.md §9.1/§10. */
#include "pdsh_task_store.h"
#include "test_secure_support.h"
#include <stdlib.h>
#include <string.h>

static const char *ME = "phone:9b6cc456bc66478c30edb378c40b490e13480ddad90e59dda9efd13e4337f03e";
static const char *OTHER = "phone:12e884cf0e94f8d764f1d46a89c5e21b4d95ab7c2c9976856fe37e99a1c960e8";
static nvs_handle_t ns(void) {
    nvs_handle_t h;
    CHECK(nvs_open("pdsh_tools", NVS_READWRITE, &h) == ESP_OK, "open");
    return h;
}
static void put_value(const char *key, const cJSON *value) {
    if (cJSON_IsString(value)) {
        fake_nvs_unreadable("pdsh_tools", key);
        return;
    }
    char *text = cJSON_PrintUnformatted(value);
    fake_nvs_put("pdsh_tools", key, text, strlen(text) + 1);
    free(text);
}
static const char *source_name(pdsh_task_store_source_t s) {
    return s == PDSH_STORE_SOURCE_V2 ? "use_v2" : s == PDSH_STORE_SOURCE_V1_MIGRATED ? "migrate_v1"
           : s == PDSH_STORE_SOURCE_EMPTY ? "empty" : "disabled";
}

static int golden(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f, "open %s", path);
    int rows = 0;
    char *line;
    while ((line = read_line(f))) {
        cJSON *row = cJSON_Parse(line);
        CHECK(row, "json");
        const char *name = cJSON_GetObjectItem(row, "name")->valuestring;
        const char *result = cJSON_GetObjectItem(row, "result")->valuestring;
        const cJSON *nvs = cJSON_GetObjectItem(row, "nvs"), *view = cJSON_GetObjectItem(row, "view");
        fake_nvs_reset();
        if (cJSON_GetObjectItem(nvs, "tasks_v1")) put_value("tasks_v1", cJSON_GetObjectItem(nvs, "tasks_v1"));
        if (cJSON_GetObjectItem(nvs, "tasks_v2")) put_value("tasks_v2", cJSON_GetObjectItem(nvs, "tasks_v2"));
        uint8_t v1_before[16384];
        size_t v1_len = 0;
        bool had_v1 = fake_nvs_get("pdsh_tools", "tasks_v1", v1_before, &v1_len);
        bool ok = pdsh_task_store_init(ns());
        CHECK(!strcmp(source_name(pdsh_task_store_source()), result), "%s: got %s want %s", name,
              source_name(pdsh_task_store_source()), result);
        CHECK(ok == (strcmp(result, "disabled") != 0), "%s: healthy", name);
        cJSON *got = pdsh_task_store_view();
        CHECK(cJSON_IsNull(view) ? got == NULL : cJSON_Compare(got, view, true), "%s: view", name);
        cJSON_Delete(got);
        const cJSON *want_digest = cJSON_GetObjectItem(row, "write_v1_sha256");
        const char *digest = pdsh_task_store_write_v1_sha256();
        CHECK(cJSON_IsNull(want_digest) ? digest == NULL : digest && !strcmp(digest, want_digest->valuestring),
              "%s: write_v1_sha256 %s", name, digest ? digest : "null");
        if (!strcmp(result, "migrate_v1")) {
            /* No write before the first mutation; then a complete v2 document
             * and an untouched tasks_v1. */
            size_t n;
            CHECK(!fake_nvs_get("pdsh_tools", "tasks_v2", NULL, &n), "%s: v2 written early", name);
            CHECK(pdsh_task_store_submit("{\"id\":\"task-9\",\"idempotency_key\":\"goal-9\",\"requester\":\"sensor\","
                                         "\"created_at\":\"2026-11-06T00:09:00Z\",\"body\":{\"type\":\"goal\","
                                         "\"text\":\"later\"}}"),
                  "%s: submit", name);
            uint8_t v1_after[16384];
            size_t after_len = 0;
            CHECK(fake_nvs_get("pdsh_tools", "tasks_v1", v1_after, &after_len) && after_len == v1_len &&
                      !memcmp(v1_after, v1_before, v1_len),
                  "%s: tasks_v1 changed", name);
            CHECK(pdsh_task_store_init(ns()) && pdsh_task_store_source() == PDSH_STORE_SOURCE_V2, "%s: reload", name);
            CHECK(!strcmp(pdsh_task_store_write_v1_sha256(), want_digest->valuestring), "%s: persisted digest", name);
            /* Roll-forward: an older firmware that changes tasks_v1 afterwards
             * disables the store (never merged, never dropped). */
            uint8_t changed[16384];
            memcpy(changed, v1_before, v1_len);
            changed[v1_len - 2] = changed[v1_len - 2] == '}' ? ']' : '}';
            fake_nvs_put("pdsh_tools", "tasks_v1", changed, v1_len);
            CHECK(!pdsh_task_store_init(ns()) && pdsh_task_store_source() == PDSH_STORE_SOURCE_DISABLED, "%s: roll-forward", name);
            CHECK(!pdsh_task_store_submit("{\"id\":\"t\",\"idempotency_key\":\"k\",\"requester\":\"s\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"x\"}}"), "%s: disabled refuses", name);
            fake_nvs_put("pdsh_tools", "tasks_v1", v1_before, v1_len);
            CHECK(pdsh_task_store_init(ns()), "%s: restored", name);
            got = pdsh_task_store_view();
            CHECK(cJSON_GetArraySize(got) == cJSON_GetArraySize(view) + 1, "%s: migrated slots", name);
            for (int i = 0; i < cJSON_GetArraySize(view); i++)
                CHECK(cJSON_Compare(cJSON_GetArrayItem(got, i), cJSON_GetArrayItem(view, i), true), "%s: slot %d", name, i);
            cJSON_Delete(got);
        } else if (!strcmp(result, "disabled") && had_v1) {
            uint8_t v1_after[16384];
            size_t after_len = 0;
            CHECK(fake_nvs_get("pdsh_tools", "tasks_v1", v1_after, &after_len) && after_len == v1_len, "%s", name);
        }
        cJSON_Delete(row);
        free(line);
        rows++;
    }
    fclose(f);
    return rows;
}

static void seed(const char *slots_json) {
    fake_nvs_reset();
    char doc[8192];
    snprintf(doc, sizeof(doc), "{\"v\":2,\"v1_sha256\":null,\"slots\":%s}", slots_json);
    fake_nvs_put("pdsh_tools", "tasks_v2", doc, strlen(doc) + 1);
    CHECK(pdsh_task_store_init(ns()), "seed");
}
#define T1 "{\"id\":\"task-1\",\"idempotency_key\":\"goal-1\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"one\"}}"
#define T2 "{\"id\":\"task-2\",\"idempotency_key\":\"goal-2\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"two\"}}"

static int transitions(void) {
    int checks = 0;
    const char *phase;
    cJSON *done = cJSON_Parse("{\"output\":\"ok\",\"truncated\":false}");
    cJSON *other = cJSON_Parse("{\"output\":\"other\",\"truncated\":false}");
    cJSON *failed = cJSON_Parse("{\"failure\":{\"kind\":\"failed\",\"message\":\"x\"}}");

    /* Legacy owner-less accepted slot: never offered, never mutated. */
    seed("[{\"task\":" T1 ",\"phase\":\"accepted\"},{\"task\":" T2 ",\"phase\":\"queued\"}]");
    cJSON *offer = pdsh_task_store_offer(ME);
    CHECK(!strcmp(cJSON_GetObjectItem(cJSON_GetObjectItem(offer, "task"), "id")->valuestring, "task-2"), "offer");
    cJSON_Delete(offer);
    CHECK(pdsh_task_store_secure("accept", "task-1", "goal-1", ME, NULL, &phase) == PDSH_STORE_WRONG_OWNER, "legacy accept");
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", ME, done, &phase) == PDSH_STORE_WRONG_OWNER, "legacy complete");
    checks += 3;

    /* Ownership: accept by ME, then OTHER sees wrong_owner, and next hides it. */
    seed("[{\"task\":" T1 ",\"phase\":\"queued\"}]");
    CHECK(pdsh_task_store_secure("accept", "task-1", "goal-9", ME, NULL, &phase) == PDSH_STORE_CONFLICT, "idem");
    CHECK(pdsh_task_store_secure("accept", "task-9", "goal-9", ME, NULL, &phase) == PDSH_STORE_UNKNOWN_TASK, "unknown");
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", ME, done, &phase) == PDSH_STORE_INVALID_TRANSITION, "queued complete");
    CHECK(pdsh_task_store_secure("accept", "task-1", "goal-1", ME, NULL, &phase) == PDSH_STORE_APPLIED && !strcmp(phase, "accepted"), "accept");
    CHECK(pdsh_task_store_secure("accept", "task-1", "goal-1", ME, NULL, &phase) == PDSH_STORE_DUPLICATE, "dup");
    CHECK(pdsh_task_store_secure("accept", "task-1", "goal-1", OTHER, NULL, &phase) == PDSH_STORE_WRONG_OWNER, "other accept");
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", OTHER, done, &phase) == PDSH_STORE_WRONG_OWNER, "other complete");
    offer = pdsh_task_store_offer(OTHER);
    CHECK(cJSON_IsNull(cJSON_GetObjectItem(offer, "task")) && cJSON_IsNull(cJSON_GetObjectItem(offer, "phase")), "hidden");
    cJSON_Delete(offer);
    /* The legacy Link core cannot touch an owned slot. */
    cJSON *legacy = cJSON_Parse("{\"id\":\"task-1\",\"output\":\"ok\",\"truncated\":false}");
    CHECK(!pdsh_task_store_transition("complete", legacy), "legacy on owned");
    cJSON_Delete(legacy);
    checks += 9;

    /* Storage failure: fatal, slot unchanged durably, store fails closed. */
    fake_nvs_fail_next_commit();
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", ME, done, &phase) == PDSH_STORE_FAILED, "storage");
    CHECK(!pdsh_task_store_healthy(), "unhealthy after uncertain write");
    CHECK(pdsh_task_store_init(ns()), "reinit");
    const char *st;
    bool mine;
    cJSON *outcome;
    CHECK(pdsh_task_store_status("task-1", "goal-1", ME, &st, &mine, &outcome) == PDSH_STORE_APPLIED &&
              !strcmp(st, "accepted") && mine && !outcome, "durable accepted");
    checks += 4;

    /* Terminal: same outcome duplicate, different conflict, other kind conflict. */
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", ME, done, &phase) == PDSH_STORE_APPLIED, "complete");
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", ME, done, &phase) == PDSH_STORE_DUPLICATE &&
              !strcmp(phase, "completed"), "complete dup");
    CHECK(pdsh_task_store_secure("complete", "task-1", "goal-1", ME, other, &phase) == PDSH_STORE_CONFLICT, "other output");
    CHECK(pdsh_task_store_secure("fail", "task-1", "goal-1", ME, failed, &phase) == PDSH_STORE_CONFLICT, "other kind");
    CHECK(pdsh_task_store_secure("accept", "task-1", "goal-1", ME, NULL, &phase) == PDSH_STORE_INVALID_TRANSITION, "terminal accept");
    CHECK(pdsh_task_store_status("task-1", "goal-1", OTHER, &st, &mine, &outcome) == PDSH_STORE_APPLIED && !mine &&
              !outcome && !strcmp(st, "completed"), "status other");
    CHECK(pdsh_task_store_status("task-1", "goal-1", ME, &st, &mine, &outcome) == PDSH_STORE_APPLIED && mine &&
              cJSON_Compare(outcome, done, true), "status mine");
    cJSON_Delete(outcome);
    cJSON *local = pdsh_task_store_result("task-1");
    CHECK(local && !strcmp(cJSON_GetObjectItem(local, "phase")->valuestring, "completed"), "local result");
    cJSON_Delete(local);
    /* Full store rejects local submission (no eviction). */
    seed("[{\"task\":" T1 ",\"phase\":\"completed\",\"by\":\"phone:9b6cc456bc66478c30edb378c40b490e13480ddad90e59dda9efd13e4337f03e\",\"outcome\":{\"output\":\"ok\",\"truncated\":false}}]");
    char task[256];
    for (int i = 2; i <= 4; i++) {
        snprintf(task, sizeof(task), "{\"id\":\"t%d\",\"idempotency_key\":\"k%d\",\"requester\":\"s\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"x\"}}", i, i);
        CHECK(pdsh_task_store_submit(task), "submit %d", i);
    }
    CHECK(!pdsh_task_store_submit("{\"id\":\"t5\",\"idempotency_key\":\"k5\",\"requester\":\"s\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"x\"}}"), "full");
    checks += 10;
    cJSON_Delete(done);
    cJSON_Delete(other);
    cJSON_Delete(failed);
    return checks;
}

int main(int argc, char **argv) {
    CHECK(argc == 2, "usage: task-store-v2 <ble-secure-task-store-cases.jsonl>");
    int rows = golden(argv[1]);
    CHECK(rows == 19, "expected 19 vectors, got %d", rows);
    int checks = transitions();
    printf("task store v2 shared vectors: %d PASS; ownership transitions: %d checks PASS\n", rows, checks);
    return 0;
}

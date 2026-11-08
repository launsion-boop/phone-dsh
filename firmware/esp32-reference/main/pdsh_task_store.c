// SPDX-License-Identifier: MIT
#include "pdsh_task_store.h"
#include "pdsh_task_validate.h"
#include <stdlib.h>
#include <string.h>

#define STORE_MAX 16384
static nvs_handle_t task_storage;
static cJSON *store; /* always the v2 document {v:2, slots:[...]} */
static bool healthy;
static pdsh_task_store_source_t source;
void pdsh_task_store_disable(void) {
    healthy = false;
    source = PDSH_STORE_SOURCE_DISABLED;
    cJSON_Delete(store);
    store = NULL;
}
pdsh_task_store_source_t pdsh_task_store_source(void) { return source; }

static const char *str(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool exact_keys(const cJSON *obj, const char *const *names, size_t n) {
    if (!cJSON_IsObject(obj) || (size_t)cJSON_GetArraySize(obj) != n) return false;
    const cJSON *v;
    cJSON_ArrayForEach(v, obj) {
        bool found = false;
        for (size_t i = 0; i < n; i++) if (v->string && !strcmp(v->string, names[i])) found = true;
        if (!found) return false;
        for (const cJSON *w = v->next; w; w = w->next)
            if (w->string && !strcmp(v->string, w->string)) return false;
    }
    return true;
}
static bool phone_id(const char *s) {
    if (!s || strncmp(s, "phone:", 6) || strlen(s) != 70) return false;
    for (size_t i = 6; i < 70; i++)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
    return true;
}
static cJSON *canonical_task(const cJSON *task) {
    if (!pdsh_task_validate(task)) return NULL;
    cJSON *copy = cJSON_CreateObject();
    if (!copy) return NULL;
    const char *keys[] = {"id", "idempotency_key", "requester", "created_at", "deadline"};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        const char *value = str(task, keys[i]);
        if (value && !cJSON_AddStringToObject(copy, keys[i], value)) goto fail;
    }
    const cJSON *source_body = cJSON_GetObjectItemCaseSensitive(task, "body");
    cJSON *body = cJSON_AddObjectToObject(copy, "body");
    if (!body || !cJSON_AddStringToObject(body, "type", "goal") ||
        !cJSON_AddStringToObject(body, "text", str(source_body, "text"))) goto fail;
    return copy;
fail:
    cJSON_Delete(copy);
    return NULL;
}
static bool valid_outcome(const char *phase, const cJSON *outcome) {
    if (!strcmp(phase, "completed")) {
        const char *keys[] = {"output", "truncated"};
        const char *text = str(outcome, "output");
        return exact_keys(outcome, keys, 2) && pdsh_task_valid_output(text, 1024) &&
               cJSON_IsBool(cJSON_GetObjectItemCaseSensitive(outcome, "truncated"));
    }
    if (!strcmp(phase, "failed")) {
        const char *keys[] = {"failure"}, *inner[] = {"kind", "message"};
        const cJSON *failure = cJSON_GetObjectItemCaseSensitive(outcome, "failure");
        const char *kind = str(failure, "kind"), *message = str(failure, "message");
        return exact_keys(outcome, keys, 1) && exact_keys(failure, inner, 2) && kind &&
               pdsh_task_valid_output(message, 256) &&
               (!strcmp(kind, "denied") || !strcmp(kind, "unavailable") || !strcmp(kind, "expired") ||
                !strcmp(kind, "failed") || !strcmp(kind, "unknown_outcome"));
    }
    return false;
}
/* version 1: v1 slots only; version 2: v1 slots plus optional owner `by` on
 * non-queued slots. */
static bool valid_store(const cJSON *root, int version) {
    const char *root_keys[] = {"v", "slots"};
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(root, "v"),
                *slots = cJSON_GetObjectItemCaseSensitive(root, "slots");
    if (!exact_keys(root, root_keys, 2) || !cJSON_IsNumber(v) || v->valuedouble != version ||
        !cJSON_IsArray(slots) || cJSON_GetArraySize(slots) > 4) return false;
    const cJSON *slot;
    cJSON_ArrayForEach(slot, slots) {
        const cJSON *task = cJSON_GetObjectItemCaseSensitive(slot, "task"),
                    *outcome = cJSON_GetObjectItemCaseSensitive(slot, "outcome");
        const cJSON *by = cJSON_GetObjectItemCaseSensitive(slot, "by");
        const char *phase = str(slot, "phase");
        if (!phase || !pdsh_task_validate(task)) return false;
        cJSON *canonical = canonical_task(task);
        bool same = canonical && cJSON_Compare(canonical, task, true);
        cJSON_Delete(canonical);
        if (!same) return false;
        bool queued = !strcmp(phase, "queued"), accepted = !strcmp(phase, "accepted");
        if (by && (version < 2 || queued || !cJSON_IsString(by) || !phone_id(by->valuestring))) return false;
        size_t extra = by ? 1 : 0;
        if (queued || accepted) {
            const char *keys[] = {"task", "phase", "by"};
            if (!exact_keys(slot, keys, 2 + extra) || (by && !cJSON_GetObjectItemCaseSensitive(slot, "by")))
                return false;
        } else {
            const char *keys[] = {"task", "phase", "outcome", "by"};
            if (!exact_keys(slot, keys, 3 + extra) || !valid_outcome(phase, outcome)) return false;
        }
        for (const cJSON *other = slot->next; other; other = other->next) {
            const cJSON *other_task = cJSON_GetObjectItemCaseSensitive(other, "task");
            const char *oid = str(other_task, "id"), *okey = str(other_task, "idempotency_key");
            if (!oid || !okey || !strcmp(str(task, "id"), oid) ||
                !strcmp(str(task, "idempotency_key"), okey)) return false;
        }
    }
    return true;
}
/* Writes a complete candidate document; the in-memory store is replaced only
 * after the commit succeeded. On failure the store becomes unhealthy because
 * the durable result is uncertain (fail closed until re-init). */
static bool persist(cJSON *candidate) {
    char *json = cJSON_PrintUnformatted(candidate);
    bool ok = false;
    if (json) {
        size_t n = strlen(json) + 1;
        ok = n <= STORE_MAX && nvs_set_blob(task_storage, "tasks_v2", json, n) == ESP_OK &&
             nvs_commit(task_storage) == ESP_OK;
        free(json);
    }
    if (!ok) {
        cJSON_Delete(candidate);
        healthy = false;
        return false;
    }
    cJSON_Delete(store);
    store = candidate;
    source = PDSH_STORE_SOURCE_V2;
    return true;
}
static cJSON *load(const char *key, esp_err_t *error) {
    char *buffer = calloc(1, STORE_MAX);
    if (!buffer) {
        *error = ESP_FAIL;
        return NULL;
    }
    size_t n = STORE_MAX;
    *error = nvs_get_blob(task_storage, key, buffer, &n);
    cJSON *root = NULL;
    if (*error == ESP_OK) {
        if (n > 1 && n <= STORE_MAX && buffer[n - 1] == 0 && strlen(buffer) == n - 1 &&
            pdsh_task_json_no_nul(buffer))
            root = cJSON_ParseWithOpts(buffer, NULL, true);
        if (!root) *error = ESP_FAIL;
    }
    free(buffer);
    return root;
}
bool pdsh_task_store_init(nvs_handle_t storage) {
    pdsh_task_store_disable();
    task_storage = storage;
    esp_err_t error;
    cJSON *root = load("tasks_v2", &error);
    if (error == ESP_OK) {
        if (pdsh_task_unique_keys(root) && valid_store(root, 2)) {
            store = root;
            source = PDSH_STORE_SOURCE_V2;
            healthy = true;
        } else cJSON_Delete(root);
        return healthy; /* never fall back to v1 once v2 exists */
    }
    if (error != ESP_ERR_NVS_NOT_FOUND) return false;
    root = load("tasks_v1", &error);
    if (error == ESP_ERR_NVS_NOT_FOUND) {
        store = cJSON_CreateObject();
        if (store && cJSON_AddNumberToObject(store, "v", 2) && cJSON_AddArrayToObject(store, "slots")) {
            healthy = true;
            source = PDSH_STORE_SOURCE_EMPTY;
        }
        return healthy;
    }
    if (error != ESP_OK || !pdsh_task_unique_keys(root) || !valid_store(root, 1)) {
        cJSON_Delete(root);
        return false;
    }
    /* Migrated view: the v1 slots, without owners; tasks_v1 is not touched. */
    cJSON_ReplaceItemInObjectCaseSensitive(root, "v", cJSON_CreateNumber(2));
    store = root;
    source = PDSH_STORE_SOURCE_V1_MIGRATED;
    healthy = true;
    return true;
}
bool pdsh_task_store_healthy(void) { return healthy; }
cJSON *pdsh_task_store_view(void) {
    return healthy ? cJSON_Duplicate(cJSON_GetObjectItemCaseSensitive(store, "slots"), true) : NULL;
}
static cJSON *candidate_copy(void) { return cJSON_Duplicate(store, true); }
static cJSON *find_slot(cJSON *doc, const char *id) {
    cJSON *slot;
    cJSON_ArrayForEach(slot, cJSON_GetObjectItemCaseSensitive(doc, "slots"))
        if (!strcmp(str(cJSON_GetObjectItemCaseSensitive(slot, "task"), "id"), id)) return slot;
    return NULL;
}

bool pdsh_task_store_submit(const char *json) {
    if (!healthy || !pdsh_task_validate_json(json)) return false;
    cJSON *source_task = cJSON_ParseWithOpts(json, NULL, true), *task = canonical_task(source_task);
    cJSON_Delete(source_task);
    if (!task) return false;
    cJSON *slot;
    cJSON_ArrayForEach(slot, cJSON_GetObjectItemCaseSensitive(store, "slots")) {
        cJSON *old = cJSON_GetObjectItemCaseSensitive(slot, "task");
        if (!strcmp(str(old, "id"), str(task, "id")) ||
            !strcmp(str(old, "idempotency_key"), str(task, "idempotency_key"))) {
            bool same = cJSON_Compare(old, task, true);
            cJSON_Delete(task);
            return same;
        }
    }
    cJSON *doc = candidate_copy(), *slots = cJSON_GetObjectItemCaseSensitive(doc, "slots");
    if (!doc || cJSON_GetArraySize(slots) >= 4) {
        cJSON_Delete(task);
        cJSON_Delete(doc);
        return false; /* no eviction: a full store rejects local submission */
    }
    slot = cJSON_CreateObject();
    if (!slot || !cJSON_AddItemToObject(slot, "task", task)) {
        cJSON_Delete(task);
        cJSON_Delete(slot);
        cJSON_Delete(doc);
        return false;
    }
    if (!cJSON_AddStringToObject(slot, "phase", "queued") || !cJSON_AddItemToArray(slots, slot)) {
        cJSON_Delete(slot);
        cJSON_Delete(doc);
        return false;
    }
    return persist(doc);
}
cJSON *pdsh_task_store_next(void) {
    if (!healthy) return NULL;
    cJSON *result = cJSON_CreateObject(), *slot;
    if (!result) return NULL;
    cJSON_ArrayForEach(slot, cJSON_GetObjectItemCaseSensitive(store, "slots")) {
        const char *phase = str(slot, "phase");
        if ((!strcmp(phase, "queued") || !strcmp(phase, "accepted")) &&
            !cJSON_GetObjectItemCaseSensitive(slot, "by")) {
            cJSON *copy = cJSON_Duplicate(cJSON_GetObjectItemCaseSensitive(slot, "task"), true);
            if (!copy || !cJSON_AddItemToObject(result, "task", copy)) {
                cJSON_Delete(copy);
                cJSON_Delete(result);
                return NULL;
            }
            return result;
        }
    }
    if (!cJSON_AddNullToObject(result, "task")) {
        cJSON_Delete(result);
        return NULL;
    }
    return result;
}
cJSON *pdsh_task_store_result(const char *id) {
    if (!healthy || !id) return NULL;
    const cJSON *slot = find_slot(store, id);
    if (!slot) return NULL;
    cJSON *result = cJSON_CreateObject();
    if (!result || !cJSON_AddStringToObject(result, "phase", str(slot, "phase"))) {
        cJSON_Delete(result);
        return NULL;
    }
    const cJSON *outcome = cJSON_GetObjectItemCaseSensitive(slot, "outcome");
    if (outcome) {
        cJSON *copy = cJSON_Duplicate(outcome, true);
        if (!copy || !cJSON_AddItemToObject(result, "outcome", copy)) {
            cJSON_Delete(copy);
            cJSON_Delete(result);
            return NULL;
        }
    }
    return result;
}
/* Owner-less legacy transitions keep their v1 meaning and never touch a slot
 * that carries an owner. */
bool pdsh_task_store_transition(const char *action, const cJSON *args) {
    if (!healthy || !action || !cJSON_IsObject(args)) return false;
    const char *id = str(args, "id");
    if (!id) return false;
    cJSON *current = find_slot(store, id);
    if (!current || cJSON_GetObjectItemCaseSensitive(current, "by")) return false;
    const char *phase = str(current, "phase");
    if (!strcmp(action, "accept")) {
        const char *keys[] = {"id"};
        if (!exact_keys(args, keys, 1)) return false;
        if (!strcmp(phase, "accepted")) return true;
        if (strcmp(phase, "queued")) return false;
        cJSON *doc = candidate_copy(), *slot = doc ? find_slot(doc, id) : NULL;
        if (!slot || !cJSON_ReplaceItemInObjectCaseSensitive(slot, "phase", cJSON_CreateString("accepted"))) {
            cJSON_Delete(doc);
            return false;
        }
        return persist(doc);
    }
    cJSON *outcome = cJSON_Duplicate(args, true);
    if (!outcome) return false;
    cJSON_DeleteItemFromObjectCaseSensitive(outcome, "id");
    const char *target = !strcmp(action, "complete") ? "completed" : !strcmp(action, "fail") ? "failed" : NULL;
    if (!target || !valid_outcome(target, outcome)) {
        cJSON_Delete(outcome);
        return false;
    }
    if (!strcmp(phase, target)) {
        bool same = cJSON_Compare(cJSON_GetObjectItemCaseSensitive(current, "outcome"), outcome, true);
        cJSON_Delete(outcome);
        return same;
    }
    if (strcmp(phase, "accepted")) {
        cJSON_Delete(outcome);
        return false;
    }
    cJSON *doc = candidate_copy(), *slot = doc ? find_slot(doc, id) : NULL;
    if (!slot || !cJSON_ReplaceItemInObjectCaseSensitive(slot, "phase", cJSON_CreateString(target)) ||
        !cJSON_AddItemToObject(slot, "outcome", outcome)) {
        if (!slot || !cJSON_GetObjectItemCaseSensitive(slot, "outcome")) cJSON_Delete(outcome);
        cJSON_Delete(doc);
        return false;
    }
    return persist(doc);
}

/* ---------------- secure-session transitions ---------------- */

static const char *phase_constant(const char *phase) {
    static const char *const names[] = {"queued", "accepted", "completed", "failed", "unknown"};
    for (size_t i = 0; i < 5; i++) if (phase && !strcmp(phase, names[i])) return names[i];
    return "unknown";
}
cJSON *pdsh_task_store_offer(const char *owner) {
    if (!healthy || !phone_id(owner)) return NULL;
    cJSON *result = cJSON_CreateObject(), *slot;
    if (!result) return NULL;
    cJSON_ArrayForEach(slot, cJSON_GetObjectItemCaseSensitive(store, "slots")) {
        const char *phase = str(slot, "phase"), *by = str(slot, "by");
        bool offer = !strcmp(phase, "queued") || (!strcmp(phase, "accepted") && by && !strcmp(by, owner));
        if (!offer) continue;
        cJSON *copy = cJSON_Duplicate(cJSON_GetObjectItemCaseSensitive(slot, "task"), true);
        if (!copy || !cJSON_AddItemToObject(result, "task", copy) ||
            !cJSON_AddStringToObject(result, "phase", phase)) {
            if (!cJSON_GetObjectItemCaseSensitive(result, "task")) cJSON_Delete(copy);
            cJSON_Delete(result);
            return NULL;
        }
        return result;
    }
    if (!cJSON_AddNullToObject(result, "task") || !cJSON_AddNullToObject(result, "phase")) {
        cJSON_Delete(result);
        return NULL;
    }
    return result;
}

pdsh_store_result_t pdsh_task_store_secure(const char *action, const char *id, const char *idem,
                                           const char *owner, const cJSON *outcome, const char **phase) {
    *phase = NULL;
    if (!healthy || !action || !id || !idem || !phone_id(owner)) return PDSH_STORE_FAILED;
    cJSON *current = find_slot(store, id);
    if (!current) return PDSH_STORE_UNKNOWN_TASK;
    if (strcmp(str(cJSON_GetObjectItemCaseSensitive(current, "task"), "idempotency_key"), idem))
        return PDSH_STORE_CONFLICT;
    const char *now = str(current, "phase"), *by = str(current, "by");
    bool mine = by && !strcmp(by, owner);
    *phase = phase_constant(now);
    const char *target;
    if (!strcmp(action, "accept")) {
        if (!strcmp(now, "accepted") && mine) return PDSH_STORE_DUPLICATE;
        if (strcmp(now, "queued")) return mine ? PDSH_STORE_INVALID_TRANSITION : PDSH_STORE_WRONG_OWNER;
        target = "accepted";
    } else {
        target = !strcmp(action, "complete") ? "completed" : !strcmp(action, "fail") ? "failed" : NULL;
        if (!target || !valid_outcome(target, outcome)) return PDSH_STORE_FAILED;
        if (!strcmp(now, "queued")) return PDSH_STORE_INVALID_TRANSITION;
        if (!mine) return PDSH_STORE_WRONG_OWNER;
        if (strcmp(now, "accepted")) {
            bool same = !strcmp(now, target) &&
                        cJSON_Compare(cJSON_GetObjectItemCaseSensitive(current, "outcome"), outcome, true);
            return same ? PDSH_STORE_DUPLICATE : PDSH_STORE_CONFLICT;
        }
    }
    cJSON *doc = candidate_copy(), *slot = doc ? find_slot(doc, id) : NULL;
    bool ok = slot && cJSON_ReplaceItemInObjectCaseSensitive(slot, "phase", cJSON_CreateString(target));
    if (ok && !cJSON_GetObjectItemCaseSensitive(slot, "by")) ok = cJSON_AddStringToObject(slot, "by", owner) != NULL;
    if (ok && strcmp(target, "accepted")) {
        cJSON *copy = cJSON_Duplicate(outcome, true);
        ok = copy && cJSON_AddItemToObject(slot, "outcome", copy);
        if (!ok) cJSON_Delete(copy);
    }
    if (!ok) {
        cJSON_Delete(doc);
        return PDSH_STORE_FAILED;
    }
    if (!persist(doc)) return PDSH_STORE_FAILED;
    *phase = phase_constant(target);
    return PDSH_STORE_APPLIED;
}

pdsh_store_result_t pdsh_task_store_status(const char *id, const char *idem, const char *owner,
                                           const char **phase, bool *mine, cJSON **outcome) {
    *phase = "unknown";
    *mine = false;
    *outcome = NULL;
    if (!healthy || !id || !idem || !phone_id(owner)) return PDSH_STORE_FAILED;
    const cJSON *slot = find_slot(store, id);
    if (!slot) return PDSH_STORE_APPLIED;
    if (strcmp(str(cJSON_GetObjectItemCaseSensitive(slot, "task"), "idempotency_key"), idem))
        return PDSH_STORE_CONFLICT;
    const char *by = str(slot, "by");
    *phase = phase_constant(str(slot, "phase"));
    *mine = by && !strcmp(by, owner);
    const cJSON *stored = cJSON_GetObjectItemCaseSensitive(slot, "outcome");
    if (*mine && stored) {
        *outcome = cJSON_Duplicate(stored, true);
        if (!*outcome) return PDSH_STORE_FAILED;
    }
    return PDSH_STORE_APPLIED;
}

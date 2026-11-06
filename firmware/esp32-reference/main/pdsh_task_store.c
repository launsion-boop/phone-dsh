// SPDX-License-Identifier: MIT
#include "pdsh_task_store.h"
#include "pdsh_task_validate.h"
#include <stdlib.h>
#include <string.h>

#define STORE_MAX 16384
static nvs_handle_t task_storage;
static cJSON *store;
static bool healthy;
void pdsh_task_store_disable(void) { healthy=false; cJSON_Delete(store); store=NULL; }

static const char *str(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool exact_keys(const cJSON *obj, const char *const *names, size_t n) {
    if (!cJSON_IsObject(obj) || (size_t)cJSON_GetArraySize(obj) != n) return false;
    const cJSON *v;
    cJSON_ArrayForEach(v, obj) {
        bool found = false;
        for (size_t i=0; i<n; i++) if (v->string && !strcmp(v->string,names[i])) found=true;
        if (!found) return false;
        for (const cJSON *w=v->next; w; w=w->next)
            if (w->string && !strcmp(v->string,w->string)) return false;
    }
    return true;
}
static cJSON *canonical_task(const cJSON *task) {
    if (!pdsh_task_validate(task)) return NULL;
    cJSON *copy = cJSON_CreateObject();
    if (!copy) return NULL;
    const char *keys[] = {"id", "idempotency_key", "requester", "created_at", "deadline"};
    for (size_t i=0; i<sizeof(keys)/sizeof(keys[0]); i++) {
        const char *value = str(task,keys[i]);
        if (value && !cJSON_AddStringToObject(copy,keys[i],value)) goto fail;
    }
    const cJSON *source = cJSON_GetObjectItemCaseSensitive(task,"body");
    cJSON *body = cJSON_AddObjectToObject(copy,"body");
    if (!body || !cJSON_AddStringToObject(body,"type","goal") ||
        !cJSON_AddStringToObject(body,"text",str(source,"text"))) goto fail;
    return copy;
fail:
    cJSON_Delete(copy); return NULL;
}
static bool valid_outcome(const char *phase, const cJSON *outcome) {
    if (!strcmp(phase,"completed")) {
        const char *keys[] = {"output","truncated"};
        const char *text = str(outcome,"output");
        return exact_keys(outcome,keys,2) && pdsh_task_valid_output(text,1024) &&
            cJSON_IsBool(cJSON_GetObjectItemCaseSensitive(outcome,"truncated"));
    }
    if (!strcmp(phase,"failed")) {
        const char *keys[] = {"failure"}, *inner[] = {"kind","message"};
        const cJSON *failure = cJSON_GetObjectItemCaseSensitive(outcome,"failure");
        const char *kind = str(failure,"kind"), *message = str(failure,"message");
        return exact_keys(outcome,keys,1) && exact_keys(failure,inner,2) && kind && pdsh_task_valid_output(message,256) &&
            (!strcmp(kind,"denied") || !strcmp(kind,"unavailable") || !strcmp(kind,"expired") ||
             !strcmp(kind,"failed") || !strcmp(kind,"unknown_outcome"));
    }
    return false;
}
static bool valid_store(const cJSON *root) {
    const char *root_keys[] = {"v","slots"};
    const cJSON *v=cJSON_GetObjectItemCaseSensitive(root,"v"), *slots=cJSON_GetObjectItemCaseSensitive(root,"slots");
    if (!exact_keys(root,root_keys,2) || !cJSON_IsNumber(v) || v->valuedouble!=1 ||
        !cJSON_IsArray(slots) || cJSON_GetArraySize(slots)>4) return false;
    const cJSON *slot;
    cJSON_ArrayForEach(slot,slots) {
        const cJSON *task=cJSON_GetObjectItemCaseSensitive(slot,"task"), *outcome=cJSON_GetObjectItemCaseSensitive(slot,"outcome");
        const char *phase=str(slot,"phase");
        if (!phase || !pdsh_task_validate(task)) return false;
        cJSON *canonical=canonical_task(task);
        bool same=canonical && cJSON_Compare(canonical,task,true);
        cJSON_Delete(canonical);
        if (!same) return false;
        if (!strcmp(phase,"queued") || !strcmp(phase,"accepted")) {
            const char *keys[]={"task","phase"}; if (!exact_keys(slot,keys,2)) return false;
        } else {
            const char *keys[]={"task","phase","outcome"};
            if (!exact_keys(slot,keys,3) || !valid_outcome(phase,outcome)) return false;
        }
        for (const cJSON *other=slot->next; other; other=other->next) {
            const cJSON *other_task=cJSON_GetObjectItemCaseSensitive(other,"task");
            const char *oid=str(other_task,"id"), *okey=str(other_task,"idempotency_key");
            if (!oid || !okey || !strcmp(str(task,"id"),oid) || !strcmp(str(task,"idempotency_key"),okey)) return false;
        }
    }
    return true;
}
static bool persist(void) {
    char *json=cJSON_PrintUnformatted(store);
    if (!json) { healthy=false; return false; }
    size_t n=strlen(json)+1;
    bool ok=n<=STORE_MAX && nvs_set_blob(task_storage,"tasks_v1",json,n)==ESP_OK && nvs_commit(task_storage)==ESP_OK;
    free(json);
    if (!ok) healthy=false;
    return ok;
}
bool pdsh_task_store_init(nvs_handle_t storage) {
    cJSON_Delete(store); store=NULL; task_storage=storage; healthy=false;
    char *buffer=calloc(1,STORE_MAX);
    if (!buffer) return false;
    size_t n=STORE_MAX;
    esp_err_t error=nvs_get_blob(storage,"tasks_v1",buffer,&n);
    if (error==ESP_ERR_NVS_NOT_FOUND) {
        store=cJSON_CreateObject();
        if (store && cJSON_AddNumberToObject(store,"v",1) && cJSON_AddArrayToObject(store,"slots")) healthy=true;
    } else if (error==ESP_OK && n>1 && n<=STORE_MAX && buffer[n-1]==0 && strlen(buffer)==n-1 && pdsh_task_json_no_nul(buffer)) {
        store=cJSON_ParseWithOpts(buffer,NULL,true);
        healthy=store && pdsh_task_unique_keys(store) && valid_store(store);
    }
    free(buffer);
    return healthy;
}
bool pdsh_task_store_healthy(void) { return healthy; }
bool pdsh_task_store_submit(const char *json) {
    if (!healthy || !pdsh_task_validate_json(json)) return false;
    cJSON *source=cJSON_ParseWithOpts(json,NULL,true), *task=canonical_task(source);
    cJSON_Delete(source);
    if (!task) return false;
    cJSON *slots=cJSON_GetObjectItemCaseSensitive(store,"slots"), *slot;
    cJSON_ArrayForEach(slot,slots) {
        cJSON *old=cJSON_GetObjectItemCaseSensitive(slot,"task");
        if (!strcmp(str(old,"id"),str(task,"id")) || !strcmp(str(old,"idempotency_key"),str(task,"idempotency_key"))) {
            bool same=cJSON_Compare(old,task,true); cJSON_Delete(task); return same;
        }
    }
    if (cJSON_GetArraySize(slots)>=4) { cJSON_Delete(task); return false; }
    slot=cJSON_CreateObject();
    if (!slot || !cJSON_AddItemToObject(slot,"task",task)) { cJSON_Delete(task); cJSON_Delete(slot); return false; }
    if (!cJSON_AddStringToObject(slot,"phase","queued") || !cJSON_AddItemToArray(slots,slot)) { cJSON_Delete(slot); return false; }
    return persist();
}
cJSON *pdsh_task_store_next(void) {
    if (!healthy) return NULL;
    cJSON *result=cJSON_CreateObject(), *slots=cJSON_GetObjectItemCaseSensitive(store,"slots"), *slot;
    if (!result) return NULL;
    cJSON_ArrayForEach(slot,slots) {
        const char *phase=str(slot,"phase");
        if (!strcmp(phase,"queued") || !strcmp(phase,"accepted")) {
            cJSON *copy=cJSON_Duplicate(cJSON_GetObjectItemCaseSensitive(slot,"task"),true);
            if (!copy || !cJSON_AddItemToObject(result,"task",copy)) { cJSON_Delete(copy); cJSON_Delete(result); return NULL; }
            return result;
        }
    }
    if (!cJSON_AddNullToObject(result,"task")) { cJSON_Delete(result); return NULL; }
    return result;
}
cJSON *pdsh_task_store_result(const char *id) {
    if (!healthy || !id) return NULL;
    const cJSON *slot, *slots=cJSON_GetObjectItemCaseSensitive(store,"slots");
    cJSON_ArrayForEach(slot,slots) {
        const cJSON *task=cJSON_GetObjectItemCaseSensitive(slot,"task");
        if (strcmp(str(task,"id"),id)) continue;
        cJSON *result=cJSON_CreateObject();
        if (!result || !cJSON_AddStringToObject(result,"phase",str(slot,"phase"))) { cJSON_Delete(result); return NULL; }
        const cJSON *outcome=cJSON_GetObjectItemCaseSensitive(slot,"outcome");
        if (outcome) {
            cJSON *copy=cJSON_Duplicate(outcome,true);
            if (!copy || !cJSON_AddItemToObject(result,"outcome",copy)) { cJSON_Delete(copy); cJSON_Delete(result); return NULL; }
        }
        return result;
    }
    return NULL;
}
bool pdsh_task_store_transition(const char *action, const cJSON *args) {
    if (!healthy || !action || !cJSON_IsObject(args)) return false;
    const char *id=str(args,"id"), *phase=NULL;
    if (!id) return false;
    cJSON *slots=cJSON_GetObjectItemCaseSensitive(store,"slots"), *slot=NULL, *item;
    cJSON_ArrayForEach(item,slots) if (!strcmp(str(cJSON_GetObjectItemCaseSensitive(item,"task"),"id"),id)) { slot=item; break; }
    if (!slot) return false;
    phase=str(slot,"phase");
    if (!strcmp(action,"accept")) {
        const char *keys[]={"id"};
        if (!exact_keys(args,keys,1)) return false;
        if (!strcmp(phase,"accepted")) return true;
        if (strcmp(phase,"queued")) return false;
        if (!cJSON_ReplaceItemInObjectCaseSensitive(slot,"phase",cJSON_CreateString("accepted"))) return false;
        return persist();
    }
    cJSON *outcome=cJSON_Duplicate(args,true);
    if (!outcome) return false;
    cJSON_DeleteItemFromObjectCaseSensitive(outcome,"id");
    const char *target=!strcmp(action,"complete") ? "completed" : !strcmp(action,"fail") ? "failed" : NULL;
    if (!target || !valid_outcome(target,outcome)) { cJSON_Delete(outcome); return false; }
    if (!strcmp(phase,target)) {
        bool same=cJSON_Compare(cJSON_GetObjectItemCaseSensitive(slot,"outcome"),outcome,true);
        cJSON_Delete(outcome); return same;
    }
    if (strcmp(phase,"accepted")) { cJSON_Delete(outcome); return false; }
    if (!cJSON_ReplaceItemInObjectCaseSensitive(slot,"phase",cJSON_CreateString(target)) ||
        !cJSON_AddItemToObject(slot,"outcome",outcome)) { cJSON_Delete(outcome); healthy=false; return false; }
    return persist();
}

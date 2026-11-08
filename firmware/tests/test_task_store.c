// SPDX-License-Identifier: MIT
#include "pdsh_task_store.h"
#include "pdsh_task_validate.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
/* tasks_v1 holds the shared v1 vectors; the v2 store writes tasks_v2
 * (ble-secure-session.md §10). */
static char disk[16384], staged[16384], v2[16384];
static size_t disk_len, staged_len, v2_len;
static bool fail_commit;
esp_err_t nvs_get_blob(nvs_handle_t h, const char *key, void *out, size_t *n) {
    (void)h; assert(!strcmp(key,"tasks_v1") || !strcmp(key,"tasks_v2"));
    const char *src=!strcmp(key,"tasks_v2") ? v2 : disk; size_t len=!strcmp(key,"tasks_v2") ? v2_len : disk_len;
    if (!len) return ESP_ERR_NVS_NOT_FOUND;
    if (*n < len) return ESP_ERR_NVS_INVALID_LENGTH;
    memcpy(out,src,len); *n=len; return ESP_OK;
}
esp_err_t nvs_set_blob(nvs_handle_t h, const char *key, const void *data, size_t n) {
    (void)h; assert(!strcmp(key,"tasks_v2") && n<=sizeof(staged));
    memcpy(staged,data,n); staged_len=n; return ESP_OK;
}
esp_err_t nvs_commit(nvs_handle_t h) {
    (void)h;
    if (fail_commit) { staged_len=0; return ESP_FAIL; }
    memcpy(v2,staged,staged_len); v2_len=staged_len; staged_len=0; return ESP_OK;
}
int main(int argc, char **argv) {
    assert(argc==3);
    FILE *file=fopen(argv[1],"rb"); assert(file);
    char line[16384]; int count=0;
    while (fgets(line,sizeof(line),file)) {
        cJSON *row=cJSON_Parse(line); assert(row);
        const cJSON *valid=cJSON_GetObjectItemCaseSensitive(row,"valid");
        const cJSON *name=cJSON_GetObjectItemCaseSensitive(row,"name");
        char *raw=strstr(line,"\"store\":"); assert(raw); raw+=strlen("\"store\":");
        size_t n=strlen(raw); while(n && (raw[n-1]=='\n' || raw[n-1]=='\r')) raw[--n]=0;
        assert(n>0 && raw[n-1]=='}'); raw[--n]=0;
        assert(n+1<=sizeof(disk)); memcpy(disk,raw,n+1); disk_len=n+1; v2_len=0;
        bool got=pdsh_task_store_init(1), expected=cJSON_IsTrue(valid);
        if(got!=expected) { fprintf(stderr,"store vector mismatch: %s\n",name->valuestring); return 1; }
        cJSON_Delete(row); count++;
    }
    fclose(file); assert(count>0);
    disk_len=0; v2_len=0; assert(pdsh_task_store_init(1));
    const char *task="{\"id\":\"task-1\",\"idempotency_key\":\"goal-1\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}";
    const char *conflict="{\"id\":\"task-1\",\"idempotency_key\":\"other\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}";
    assert(pdsh_task_store_submit(task)); assert(pdsh_task_store_submit(task)); assert(!pdsh_task_store_submit(conflict));
    assert(pdsh_task_store_init(1));
    cJSON *next=pdsh_task_store_next(); assert(cJSON_IsObject(cJSON_GetObjectItemCaseSensitive(next,"task"))); cJSON_Delete(next);
    cJSON *accept=cJSON_Parse("{\"id\":\"task-1\"}"); assert(pdsh_task_store_transition("accept",accept)); assert(pdsh_task_store_transition("accept",accept)); cJSON_Delete(accept);
    cJSON *complete=cJSON_Parse("{\"id\":\"task-1\",\"output\":\"OK\",\"truncated\":false}");
    assert(pdsh_task_store_transition("complete",complete)); assert(pdsh_task_store_transition("complete",complete)); cJSON_Delete(complete);
    cJSON *bad=cJSON_Parse("{\"id\":\"task-1\",\"output\":\"different\",\"truncated\":false}"); assert(!pdsh_task_store_transition("complete",bad)); cJSON_Delete(bad);
    assert(pdsh_task_store_init(1)); next=pdsh_task_store_next(); assert(cJSON_IsNull(cJSON_GetObjectItemCaseSensitive(next,"task"))); cJSON_Delete(next);
    fail_commit=true; assert(!pdsh_task_store_submit("{\"id\":\"task-2\",\"idempotency_key\":\"goal-2\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}"));
    assert(!pdsh_task_store_healthy()); fail_commit=false; assert(pdsh_task_store_init(1));
    file=fopen(argv[2],"rb"); assert(file); int outcomes=0;
    while (fgets(line,sizeof(line),file)) {
        cJSON *row=cJSON_Parse(line); assert(row);
        const cJSON *valid=cJSON_GetObjectItemCaseSensitive(row,"valid"), *action=cJSON_GetObjectItemCaseSensitive(row,"action");
        char *raw=strstr(line,"\"body\":"); assert(raw); raw+=strlen("\"body\":");
        size_t n=strlen(raw); while(n && (raw[n-1]=='\n' || raw[n-1]=='\r')) raw[--n]=0;
        assert(n>0 && raw[n-1]=='}'); raw[--n]=0;
        disk_len=0; v2_len=0; assert(pdsh_task_store_init(1)); assert(pdsh_task_store_submit(task));
        cJSON *approved=cJSON_Parse("{\"id\":\"task-1\"}"); assert(pdsh_task_store_transition("accept",approved)); cJSON_Delete(approved);
        bool got=false;
        if (pdsh_task_json_no_nul(raw)) {
            cJSON *body=cJSON_Parse(raw); assert(body); cJSON_AddStringToObject(body,"id","task-1");
            got=pdsh_task_store_transition(action->valuestring,body); cJSON_Delete(body);
        }
        assert(got==cJSON_IsTrue(valid)); cJSON_Delete(row); outcomes++;
    }
    fclose(file); assert(outcomes>0);
    printf("device task outcome shared vectors: %d PASS\n",outcomes);
    printf("device task store shared vectors: %d PASS; persistence, conflicts, commit failure PASS\n",count);
    return 0;
}

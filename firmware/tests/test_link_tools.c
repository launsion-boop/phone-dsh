// SPDX-License-Identifier: MIT
#include "link_tools.h"
#include "pdsh_home.h"
#include "pdsh_link_wire.h"
#include "test_platform.h"
#include <stdio.h>
static uint64_t clock_us = 1000000;
static int gpio_level, gpio_writes, http_requests, fail_commit;
static void (*job_fn)(void *);
static void *job_arg;
typedef struct {
    char key[24];
    size_t n;
    uint8_t data[4400];
} entry_t;
static entry_t disk[40], pending_disk[40];
static bool staged;
static entry_t *find(entry_t *entries, const char *key) {
    for (int i = 0; i < 40; i++)
        if (!strcmp(entries[i].key, key))
            return &entries[i];
    return NULL;
}
esp_err_t nvs_open(const char *name, int mode, nvs_handle_t *h) {
    (void)name;
    (void)mode;
    *h = 1;
    return ESP_OK;
}
esp_err_t nvs_get_blob(nvs_handle_t h, const char *key, void *out, size_t *n) {
    (void)h;
    entry_t *e = find(disk, key);
    if (!e)
        return ESP_ERR_NVS_NOT_FOUND;
    if (*n < e->n)
        return ESP_ERR_NVS_INVALID_LENGTH;
    memcpy(out, e->data, e->n);
    *n = e->n;
    return ESP_OK;
}
esp_err_t nvs_set_blob(nvs_handle_t h, const char *key, const void *data, size_t n) {
    (void)h;
    assert(n < 4400);
    if (!staged) {
        memcpy(pending_disk, disk, sizeof(disk));
        staged = true;
    }
    entry_t *e = find(pending_disk, key);
    if (!e)
        for (int i = 0; i < 40; i++)
            if (!pending_disk[i].key[0]) {
                e = &pending_disk[i];
                break;
            }
    assert(e);
    strcpy(e->key, key);
    e->n = n;
    memcpy(e->data, data, n);
    return ESP_OK;
}
esp_err_t nvs_get_u32(nvs_handle_t h, const char *key, uint32_t *out) {
    size_t n = 4;
    return nvs_get_blob(h, key, out, &n);
}
esp_err_t nvs_set_u32(nvs_handle_t h, const char *key, uint32_t value) {
    return nvs_set_blob(h, key, &value, 4);
}
esp_err_t nvs_commit(nvs_handle_t h) {
    (void)h;
    if (fail_commit) {
        staged = false;
        return ESP_FAIL;
    }
    if (staged)
        memcpy(disk, pending_disk, sizeof(disk));
    staged = false;
    return ESP_OK;
}
int64_t esp_timer_get_time(void) { return clock_us; }
void esp_fill_random(void *out, size_t n) { memset(out, 0x42, n); }
esp_err_t gpio_reset_pin(int pin) {
    (void)pin;
    return ESP_OK;
}
esp_err_t gpio_set_direction(int pin, int mode) {
    (void)pin;
    (void)mode;
    return ESP_OK;
}
esp_err_t gpio_set_level(int pin, int value) {
    (void)pin;
    gpio_level = value;
    gpio_writes++;
    return ESP_OK;
}
int gpio_get_level(int pin) {
    (void)pin;
    return gpio_level;
}
SemaphoreHandle_t xSemaphoreCreateMutex(void) { return (void *)1; }
int xSemaphoreTake(SemaphoreHandle_t h, unsigned timeout) {
    (void)h;
    (void)timeout;
    return 1;
}
int xSemaphoreGive(SemaphoreHandle_t h) {
    (void)h;
    return 1;
}
int xTaskCreate(void (*fn)(void *), const char *name, unsigned stack, void *arg, unsigned priority,
                void *handle) {
    (void)name;
    (void)stack;
    (void)priority;
    (void)handle;
    assert(!job_fn);
    job_fn = fn;
    job_arg = arg;
    return pdPASS;
}
void vTaskDelete(void *h) { (void)h; }
struct fake_http {
    char url[340];
    bool redirect;
    size_t read;
};
static struct fake_http http;
esp_transport_handle_t xl_home_transport_create(int64_t deadline) {
    assert(deadline > (int64_t)clock_us);
    return (void *)1;
}
void esp_transport_destroy(esp_transport_handle_t handle) { (void)handle; }
esp_http_client_handle_t esp_http_client_init(const esp_http_client_config_t *c) {
    assert(c->disable_auto_redirect);
    memset(&http, 0, sizeof(http));
    strcpy(http.url, c->url);
    http.redirect = strstr(c->url, "redirect") != NULL;
    return &http;
}
esp_err_t esp_http_client_set_header(esp_http_client_handle_t h, const char *n, const char *v) {
    (void)h;
    (void)n;
    (void)v;
    return ESP_OK;
}
esp_err_t esp_http_client_set_timeout_ms(esp_http_client_handle_t h, int n) {
    (void)h;
    assert(n > 0);
    return ESP_OK;
}
esp_err_t esp_http_client_open(esp_http_client_handle_t h, int n) {
    (void)h;
    (void)n;
    http_requests++;
    return ESP_OK;
}
int esp_http_client_write(esp_http_client_handle_t h, const char *data, int n) {
    (void)h;
    (void)data;
    return n;
}
int64_t esp_http_client_fetch_headers(esp_http_client_handle_t h) {
    (void)h;
    return 2;
}
int esp_http_client_get_status_code(esp_http_client_handle_t h) { return h->redirect ? 302 : 200; }
int esp_http_client_read(esp_http_client_handle_t h, char *out, int n) {
    if (h->read)
        return 0;
    assert(n >= 2);
    memcpy(out, "OK", 2);
    h->read = 2;
    return 2;
}
bool esp_http_client_is_complete_data_received(esp_http_client_handle_t h) { return h->read == 2; }
esp_err_t esp_http_client_close(esp_http_client_handle_t h) {
    (void)h;
    return ESP_OK;
}
esp_err_t esp_http_client_cleanup(esp_http_client_handle_t h) {
    (void)h;
    return ESP_OK;
}
static void run_job(void) {
    assert(job_fn);
    void (*fn)(void *) = job_fn;
    void *arg = job_arg;
    job_fn = NULL;
    job_arg = NULL;
    fn(arg);
}
static void crash_job(void) {
    struct job {
        int slot;
        char *json;
        int64_t deadline;
    };
    struct job *j = job_arg;
    assert(j);
    free(j->json);
    free(j);
    job_fn = NULL;
    job_arg = NULL;
}
static void id_for(int value, uint8_t out[16], char text[37]) {
    memset(out, 0, 16);
    out[15] = (uint8_t)value;
    snprintf(text, 37, "00000000-0000-0000-0000-%012x", value);
}
static void put16(uint8_t *p, uint16_t v) {
    p[0] = v;
    p[1] = v >> 8;
}
static int upload_json(const uint8_t id[16], const char *json) {
    size_t total = strlen(json);
    uint8_t body[505], out[505];
    for (size_t off = 0; off < total; off += 481) {
        size_t take = total - off;
        if (take > 481)
            take = 481;
        memcpy(body, id, 16);
        put16(body + 16, total);
        put16(body + 18, off);
        body[20] = 0x98;
        body[21] = 0x3a;
        body[22] = body[23] = 0;
        memcpy(body + 24, json + off, take);
        size_t n = tools_request(PDSH_UPLOAD, body, take + 24, out);
        if (out[0])
            return out[0];
        assert(n == 3);
    }
    return 0;
}
static int submit(int value, const char *name, const char *args, const char *key,
                  uint8_t out[505]) {
    uint8_t id[16];
    char id_text[37], json[4097];
    id_for(value, id, id_text);
    snprintf(json, sizeof(json),
             "{\"request_id\":\"%s\",\"name\":\"%s\",\"args\":%s,\"idem_key\":\"%s\"}", id_text,
             name, args, key);
    int error = upload_json(id, json);
    if (error)
        return error;
    tools_request(PDSH_COMMIT, id, 16, out);
    return out[0];
}
static cJSON *query(int value, int *state) {
    uint8_t id[18] = {0}, out[505];
    char text[37], result[4097] = {0};
    id_for(value, id, text);
    size_t used = 0, total = 0;
    do {
        put16(id + 16, used);
        size_t n = tools_request(PDSH_RESULT, id, 18, out);
        assert(out[0] == 0 && n >= 6);
        *state = out[1];
        if (*state != 2)
            return NULL;
        total = out[2] | (size_t)out[3] << 8;
        assert((out[4] | (size_t)out[5] << 8) == used && n > 6);
        memcpy(result + used, out + 6, n - 6);
        used += n - 6;
    } while (used < total);
    assert(used == total);
    return cJSON_Parse(result);
}
static void task_tests(void) {
    uint8_t out[505]; int state;
    const char *task = "{\"id\":\"task-1\",\"idempotency_key\":\"key-1\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}";
    tools_init(1);
    tools_set_task_profile(PDSH_APP_TOOLS | PDSH_APP_TASKS);
    assert(tools_task_submit(task));
    assert(submit(100,"pdsh.task.next","{}","next-1",out)==0 && !job_fn);
    cJSON *reply=query(100,&state);
    const cJSON *value=cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(reply,"result"),"task");
    assert(state==2 && cJSON_IsObject(value)); cJSON_Delete(reply);
    assert(submit(101,"pdsh.task.accept","{\"id\":\"task-1\"}","accept-1",out)==0 && job_fn);
    run_job(); reply=query(101,&state);
    assert(state==2 && !strcmp(cJSON_GetObjectItemCaseSensitive(reply,"status")->valuestring,"completed")); cJSON_Delete(reply);
    tools_init(2);
    tools_set_task_profile(PDSH_APP_TOOLS | PDSH_APP_TASKS);
    reply=query(101,&state); assert(state==2); cJSON_Delete(reply);
    assert(submit(102,"pdsh.task.complete","{\"id\":\"task-1\",\"output\":\"done\",\"truncated\":false}","complete-1",out)==0 && job_fn);
    run_job(); reply=query(102,&state);
    assert(state==2 && !strcmp(cJSON_GetObjectItemCaseSensitive(reply,"status")->valuestring,"completed")); cJSON_Delete(reply);
    cJSON *local=tools_task_result("task-1");
    assert(local && !strcmp(cJSON_GetObjectItemCaseSensitive(local,"phase")->valuestring,"completed"));
    assert(!strcmp(cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(local,"outcome"),"output")->valuestring,"done"));
    cJSON_Delete(local);
    assert(submit(103,"pdsh.task.next","{}","next-2",out)==0);
    reply=query(103,&state);
    value=cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(reply,"result"),"task");
    assert(state==2 && cJSON_IsNull(value)); cJSON_Delete(reply);
    puts("Link task inbox: submit, next, durable accept, reboot, complete PASS");
}
static void negotiation_tests(const char *path) {
    FILE *f=fopen(path,"rb"); assert(f);
    char line[1024]; int rows=0;
    while (fgets(line,sizeof(line),f)) {
        cJSON *row=cJSON_Parse(line); assert(row);
        cJSON *caps=cJSON_GetObjectItemCaseSensitive(row,"app_caps"), *enabled=cJSON_GetObjectItemCaseSensitive(row,"task_tools");
        assert(cJSON_IsNumber(caps) && cJSON_IsBool(enabled));
        tools_init(1); tools_set_task_profile((uint32_t)caps->valuedouble);
        uint8_t out[505]; int state;
        assert(submit(100,"tools/list","{}","discover",out)==0);
        cJSON *reply=query(100,&state);
        cJSON *list=cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(reply,"result"),"tools");
        assert(cJSON_GetArraySize(list)==(cJSON_IsTrue(enabled) ? 7 : 3)); cJSON_Delete(reply);
        int status=submit(101,"pdsh.task.next","{}","next",out);
        assert((status==0)==cJSON_IsTrue(enabled));
        cJSON_Delete(row); rows++;
    }
    fclose(f); assert(rows>0); printf("BLE task negotiation vectors: %d PASS\n",rows);
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--task")) { task_tests(); return 0; }
    if (argc == 3 && !strcmp(argv[1], "--negotiation")) { negotiation_tests(argv[2]); return 0; }
    uint8_t out[505];
    int state;
    tools_init(1);
    assert(submit(100, "tools/list", "{}", "discover", out) == 0 && !job_fn);
    cJSON *list_result = query(100, &state);
    cJSON *listed = cJSON_GetObjectItem(cJSON_GetObjectItem(list_result, "result"), "tools");
    assert(cJSON_GetArraySize(listed) == 3);
    assert(cJSON_IsObject(cJSON_GetObjectItem(cJSON_GetArrayItem(listed, 0), "inputSchema")));
    cJSON_Delete(list_result);
    int before = gpio_writes;
    assert(submit(1, "light.set", "{\"on\":true}", "once", out) == 0 && out[1] == 1);
    assert(gpio_writes == before);
    run_job();
    assert(gpio_writes == before + 1 && gpio_level == 1);
    cJSON *r = query(1, &state);
    assert(state == 2 && !strcmp(cJSON_GetObjectItem(r, "status")->valuestring, "completed"));
    cJSON_Delete(r);
    assert(submit(1, "light.set", "{\"on\":true}", "once", out) == 0 && !job_fn);
    assert(gpio_writes == before + 1);
    assert(submit(1, "light.set", "{\"on\":false}", "once", out) == 5);
    tools_reset_upload();
    assert(submit(2, "light.set", "{\"on\":true}", "once", out) == 5);
    tools_reset_upload();
    assert(submit(3, "home.http", "{\"method\":\"GET\",\"url\":\"http://8.8.8.8/\"}", "bad-url",
                  out) != 0);
    assert(!http_requests);
    tools_reset_upload();
    assert(submit(4, "home.http",
                  "{\"method\":\"GET\",\"url\":\"http://192.168.1.50:8123/redirect\"}", "home-once",
                  out) == 0);
    run_job();
    assert(http_requests == 1);
    r = query(4, &state);
    assert(state == 2);
    cJSON *value = cJSON_GetObjectItem(r, "result");
    assert(cJSON_GetObjectItem(value, "http_status")->valueint == 302);
    cJSON_Delete(r);
    tools_reset_upload();
    assert(submit(4, "home.http",
                  "{\"method\":\"GET\",\"url\":\"http://192.168.1.50:8123/redirect\"}", "home-once",
                  out) == 0 &&
           !job_fn && http_requests == 1);
    tools_reset_upload();
    assert(submit(5, "light.set", "{\"on\":false}", "interrupted", out) == 0);
    crash_job();
    tools_init(2);
    assert(query(5, &state) == NULL && state == 3);
    int reset = gpio_writes;
    assert(submit(101, "light.get", "{}", "inspect-after-reboot", out) == 0 && !job_fn);
    cJSON *current = query(101, &state);
    cJSON *current_state = cJSON_GetObjectItem(current, "result");
    assert(cJSON_IsFalse(cJSON_GetObjectItem(current_state, "on")));
    assert(cJSON_GetObjectItem(current_state, "boot_id")->valueint == 2);
    cJSON_Delete(current);
    assert(submit(5, "light.set", "{\"on\":false}", "interrupted", out) == 0 && out[1] == 3 &&
           !job_fn && gpio_writes == reset);
    tools_reset_upload();
    fail_commit = 1;
    assert(submit(6, "light.set", "{\"on\":true}", "disk-fail", out) != 0 && !job_fn &&
           gpio_writes == reset);
    fail_commit = 0;
    tools_init(3);
    tools_reset_upload();
    int old_gpio = gpio_writes;
    assert(submit(7, "light.set", "{\"on\":true}", "expires-in-queue", out) == 0);
    clock_us += 16000000;
    run_job();
    assert(gpio_writes == old_gpio);
    r = query(7, &state);
    assert(state == 2 && !strcmp(cJSON_GetObjectItem(r, "status")->valuestring, "failed"));
    cJSON_Delete(r);
    for (int i = 10; i < 40; i++) {
        char key[30];
        snprintf(key, sizeof(key), "bounded-%d", i);
        int result = submit(i, "light.set", "{\"on\":true}", key, out);
        if (result == 15)
            break;
        assert(!result);
        run_job();
    }
    tools_reset_upload();
    assert(submit(99, "light.set", "{\"on\":true}", "full", out) == 15 && !job_fn);
    puts("link tools: durable intents, duplicate/conflict, redirect, private origin, reboot and "
         "full ledger PASS");
    return 0;
}

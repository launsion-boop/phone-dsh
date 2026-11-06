// SPDX-License-Identifier: MIT
#include "link_tools.h"
#include "driver/gpio.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs.h"
#include "pdsh_home.h"
#include "pdsh_link_wire.h"
#include "pdsh_task_store.h"
#include "pdsh_task_validate.h"
#include "psa/crypto.h"
#include "sdkconfig.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RECEIPTS 16
#define MAGIC 0x50445348u
typedef struct {
    uint32_t magic;
    uint8_t id[16], key[32], digest[32], state;
    uint16_t len;
    char result[PDSH_RPC_MAX + 1];
} receipt_t;
static receipt_t receipts[RECEIPTS], readonly_result;
static pdsh_upload_t upload;
static nvs_handle_t storage;
static bool healthy, busy, light_available;
static uint32_t boot, revision;
static char device_id[37];
static SemaphoreHandle_t lock;
static bool hash256(const uint8_t *p, size_t n, uint8_t out[32]) {
    size_t count = 0;
    return psa_hash_compute(PSA_ALG_SHA_256, p, n, out, 32, &count) == PSA_SUCCESS && count == 32;
}
static uint64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static uint16_t u16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }
static void uuid_text(const uint8_t id[16], char out[37]) {
    snprintf(out, 37, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", id[0],
             id[1], id[2], id[3], id[4], id[5], id[6], id[7], id[8], id[9], id[10], id[11], id[12],
             id[13], id[14], id[15]);
}
const char *tools_device_id(void) { return device_id; }
static bool save(int slot) {
    char key[8];
    snprintf(key, sizeof(key), "r%02d", slot);
    return nvs_set_blob(storage, key, &receipts[slot], sizeof(receipt_t)) == ESP_OK &&
           nvs_commit(storage) == ESP_OK;
}
static const char *str(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool keys(const cJSON *o, const char *const *names, size_t count) {
    if (!cJSON_IsObject(o))
        return false;
    const cJSON *v;
    cJSON_ArrayForEach(v, o) {
        bool found = false;
        for (size_t i = 0; i < count; i++)
            if (v->string && !strcmp(v->string, names[i]))
                found = true;
        if (!found)
            return false;
        for (const cJSON *w = v->next; w; w = w->next)
            if (w->string && !strcmp(v->string, w->string))
                return false;
    }
    return true;
}
static void result_json(receipt_t *r, const char *status, cJSON *value) {
    char id[37];
    uuid_text(r->id, id);
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "request_id", id);
    cJSON_AddStringToObject(root, "status", status);
    cJSON_AddItemToObject(root, "result", value ? value : cJSON_CreateObject());
    bool ok = cJSON_PrintPreallocated(root, r->result, sizeof(r->result), false);
    cJSON_Delete(root);
    r->len = ok ? strlen(r->result) : 0;
    r->state = ok ? 2 : 3;
}
static cJSON *light_state(void) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "on",
                          light_available ? gpio_get_level(CONFIG_PDSH_LED_GPIO) != 0 : false);
    cJSON_AddNumberToObject(o, "state_revision", revision);
    cJSON_AddNumberToObject(o, "boot_id", boot);
    cJSON_AddStringToObject(o, "state_source", "gpio_level");
    return o;
}
static void add_schema(cJSON *tool, const char *schema) {
    cJSON_AddItemToObject(tool, "inputSchema", cJSON_Parse(schema));
}
static cJSON *tool_list(void) {
    cJSON *o = cJSON_CreateObject(), *list = cJSON_AddArrayToObject(o, "tools");
    if (light_available) {
        cJSON *t = cJSON_CreateObject();
        cJSON_AddStringToObject(t, "name", "light.set");
        cJSON_AddStringToObject(t, "description",
                                "Set the configured discrete LED GPIO; args: {on: boolean}");
        add_schema(t, "{\"type\":\"object\",\"properties\":{\"on\":{\"type\":\"boolean\"}},"
                      "\"required\":[\"on\"],\"additionalProperties\":false}");
        cJSON_AddItemToArray(list, t);
        t = cJSON_CreateObject();
        cJSON_AddStringToObject(t, "name", "light.get");
        cJSON_AddStringToObject(t, "description", "Read current LED GPIO and revision; args: {}");
        add_schema(t, "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}");
        cJSON_AddItemToArray(list, t);
    }
    if (strlen(CONFIG_PDSH_HOME_ORIGIN) > 0 && strlen(CONFIG_PDSH_WIFI_SSID) > 0) {
        cJSON *t = cJSON_CreateObject();
        cJSON_AddStringToObject(t, "name", "home.http");
        cJSON_AddStringToObject(t, "description",
                                "Bounded HTTP to firmware-approved private origin. Returns HTTP "
                                "response, not proof of endpoint action.");
        add_schema(t, "{\"type\":\"object\",\"properties\":{\"method\":{\"type\":\"string\","
                      "\"enum\":[\"GET\",\"POST\",\"PUT\",\"PATCH\",\"DELETE\"]},\"url\":{\"type\":"
                      "\"string\"},\"headers\":{\"type\":\"object\"},\"body\":{\"type\":\"string\"}"
                      ",\"timeout_ms\":{\"type\":\"integer\",\"minimum\":1000,\"maximum\":10000}},"
                      "\"required\":[\"method\",\"url\"],\"additionalProperties\":false}");
        cJSON_AddItemToArray(list, t);
    }
    if (pdsh_task_store_healthy()) {
        const char *names[] = {"pdsh.task.next", "pdsh.task.accept", "pdsh.task.complete", "pdsh.task.fail"};
        const char *schemas[] = {
            "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
            "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}",
            "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"output\":{\"type\":\"string\"},\"truncated\":{\"type\":\"boolean\"}},\"required\":[\"id\",\"output\",\"truncated\"],\"additionalProperties\":false}",
            "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"failure\":{\"type\":\"object\"}},\"required\":[\"id\",\"failure\"],\"additionalProperties\":false}"
        };
        for (size_t i=0; i<4; i++) {
            cJSON *t=cJSON_CreateObject();
            cJSON_AddStringToObject(t,"name",names[i]);
            cJSON_AddStringToObject(t,"description","Device task control operation; host only.");
            add_schema(t,schemas[i]); cJSON_AddItemToArray(list,t);
        }
    }
    cJSON_AddStringToObject(o, "device_id", device_id);
    cJSON_AddNumberToObject(o, "boot_id", boot);
    return o;
}
typedef struct {
    int slot;
    char *json;
    int64_t deadline;
} job_t;
static void execute(void *arg) {
    job_t *job = arg;
    cJSON *root = cJSON_Parse(job->json);
    const char *name = str(root, "name");
    cJSON *args = cJSON_GetObjectItemCaseSensitive(root, "args");
    cJSON *result = NULL;
    const char *status = "completed";
    if (esp_timer_get_time() >= job->deadline) {
        status = "failed";
        result = cJSON_CreateObject();
        cJSON_AddStringToObject(result, "failure_reason", "expired");
    } else if (name && (!strcmp(name,"pdsh.task.accept") || !strcmp(name,"pdsh.task.complete") || !strcmp(name,"pdsh.task.fail"))) {
        xSemaphoreTake(lock, portMAX_DELAY);
        bool ok=pdsh_task_store_transition(name+strlen("pdsh.task."),args);
        bool task_healthy=pdsh_task_store_healthy();
        xSemaphoreGive(lock);
        result=cJSON_CreateObject();
        if (!ok) status=task_healthy ? "failed" : "outcome_unknown";
    } else if (name && !strcmp(name, "light.set")) {
        const cJSON *on = cJSON_GetObjectItemCaseSensitive(args, "on");
        if (!light_available || gpio_set_level(CONFIG_PDSH_LED_GPIO, cJSON_IsTrue(on)) != ESP_OK) {
            status = "outcome_unknown";
        } else {
            revision++;
            result = light_state();
        }
    } else if (name && !strcmp(name, "home.http")) {
        xl_home_request_t *r = calloc(1, sizeof(*r));
        if (r && pdsh_home_parse(args, r)) {
            result = pdsh_home_run(r, job->deadline);
            const char *outcome = str(result, "outcome");
            if (outcome && !strcmp(outcome, "outcome_unknown"))
                status = "outcome_unknown";
        } else {
            status = "failed";
            result = cJSON_CreateObject();
            cJSON_AddStringToObject(result, "failure_reason", "invalid_argument");
        }
        if (r) {
            memset(r, 0, sizeof(*r));
            free(r);
        }
    } else
        status = "failed";
    xSemaphoreTake(lock, portMAX_DELAY);
    receipt_t *receipt = &receipts[job->slot];
    result_json(receipt, status, result);
    if (nvs_set_u32(storage, "revision", revision) != ESP_OK || !save(job->slot)) {
        receipt->state = 3;
        receipt->len = 0;
        healthy = false;
    }
    busy = false;
    xSemaphoreGive(lock);
    cJSON_Delete(root);
    memset(job->json, 0, strlen(job->json));
    free(job->json);
    free(job);
    vTaskDelete(NULL);
}
void tools_init(uint32_t boot_id) {
    memset(receipts, 0, sizeof(receipts));
    memset(&readonly_result, 0, sizeof(readonly_result));
    memset(&upload, 0, sizeof(upload));
    busy = false;
    revision = 0;
    boot = boot_id;
    lock = xSemaphoreCreateMutex();
    healthy = psa_crypto_init() == PSA_SUCCESS &&
              nvs_open("pdsh_tools", NVS_READWRITE, &storage) == ESP_OK;
    uint8_t id[16] = {0};
    size_t len = sizeof(id);
    esp_err_t identity = healthy ? nvs_get_blob(storage, "device_id", id, &len) : ESP_FAIL;
    if (healthy && identity == ESP_ERR_NVS_NOT_FOUND) {
        esp_fill_random(id, sizeof(id));
        id[6] = (id[6] & 15) | 64;
        id[8] = (id[8] & 63) | 128;
        healthy = nvs_set_blob(storage, "device_id", id, sizeof(id)) == ESP_OK &&
                  nvs_commit(storage) == ESP_OK;
    } else if (!healthy || identity != ESP_OK || len != sizeof(id))
        healthy = false;
    uuid_text(id, device_id);
    esp_err_t rev = nvs_get_u32(storage, "revision", &revision);
    if (rev != ESP_OK && rev != ESP_ERR_NVS_NOT_FOUND)
        healthy = false;
    for (int i = 0; i < RECEIPTS && healthy; i++) {
        char key[8];
        snprintf(key, sizeof(key), "r%02d", i);
        len = sizeof(receipt_t);
        esp_err_t err = nvs_get_blob(storage, key, &receipts[i], &len);
        if (err == ESP_ERR_NVS_NOT_FOUND)
            continue;
        if (err != ESP_OK || len != sizeof(receipt_t) || receipts[i].magic != MAGIC ||
            receipts[i].state < 1 || receipts[i].state > 3 || receipts[i].len > PDSH_RPC_MAX) {
            memset(receipts, 0, sizeof(receipts));
            healthy = false;
            break;
        }
        if (receipts[i].state == 1) {
            receipts[i].state = 3;
            receipts[i].len = 0;
        }
    }
    if (healthy) (void)pdsh_task_store_init(storage); else pdsh_task_store_disable();
    light_available = CONFIG_PDSH_LED_GPIO >= 0 &&
                      CONFIG_PDSH_LED_GPIO != CONFIG_PDSH_BUTTON_GPIO &&
                      gpio_reset_pin(CONFIG_PDSH_LED_GPIO) == ESP_OK &&
                      gpio_set_direction(CONFIG_PDSH_LED_GPIO, GPIO_MODE_INPUT_OUTPUT) == ESP_OK &&
                      gpio_set_level(CONFIG_PDSH_LED_GPIO, 0) == ESP_OK;
}
bool tools_task_submit(const char *json) {
    if (!lock) return false;
    xSemaphoreTake(lock, portMAX_DELAY);
    bool ok=healthy && pdsh_task_store_submit(json);
    xSemaphoreGive(lock);
    return ok;
}
cJSON *tools_task_result(const char *id) {
    if (!lock) return NULL;
    xSemaphoreTake(lock, portMAX_DELAY);
    cJSON *result=healthy ? pdsh_task_store_result(id) : NULL;
    xSemaphoreGive(lock);
    return result;
}
void tools_reset_upload(void) {
    xSemaphoreTake(lock, portMAX_DELAY);
    memset(&upload, 0, sizeof(upload));
    memset(&readonly_result, 0, sizeof(readonly_result));
    xSemaphoreGive(lock);
}
static bool bounded_json(const uint8_t *text, size_t length) {
    int depth = 0;
    bool string = false, escape = false;
    for (size_t i = 0; i < length; i++) {
        uint8_t c = text[i];
        if (string) {
            if (escape)
                escape = false;
            else if (c == '\\')
                escape = true;
            else if (c == '"')
                string = false;
        } else if (c == '"')
            string = true;
        else if (c == '{' || c == '[') {
            if (++depth > 16)
                return false;
        } else if (c == '}' || c == ']') {
            if (--depth < 0)
                return false;
        }
    }
    return !string && depth == 0;
}
static int commit(const uint8_t id[16], uint8_t *state) {
    for (int i = 0; i < RECEIPTS; i++)
        if (receipts[i].magic == MAGIC && !memcmp(id, receipts[i].id, 16)) {
            if (upload.active && !memcmp(upload.id, id, 16)) {
                uint8_t digest[32];
                if (upload.used != upload.total)
                    return 2;
                if (!hash256(upload.data, upload.total, digest))
                    return 11;
                if (memcmp(digest, receipts[i].digest, 32))
                    return 5;
                memset(&upload, 0, sizeof(upload));
            }
            *state = receipts[i].state;
            return 0;
        }
    if (readonly_result.magic == MAGIC && !memcmp(id, readonly_result.id, 16)) {
        *state = readonly_result.state;
        return 0;
    }
    if (!upload.active || memcmp(id, upload.id, 16) || upload.used != upload.total)
        return 13;
    if (now_ms() >= upload.deadline_ms)
        return 9;
    // JSON C strings cannot represent embedded NUL. Reject before any parser can truncate them.
    if (!bounded_json(upload.data, upload.total) || memchr(upload.data, 0, upload.total) ||
        !pdsh_task_json_no_nul((char *)upload.data)) {
        upload.active = false;
        return 2;
    }
    cJSON *root = cJSON_ParseWithLengthOpts((char *)upload.data, upload.total + 1, NULL, true);
    const char *const fields[] = {"request_id", "name", "args", "idem_key"};
    const char *request_id = str(root, "request_id"), *name = str(root, "name"),
               *idem = str(root, "idem_key");
    char expected[37];
    uuid_text(id, expected);
    cJSON *args = cJSON_GetObjectItemCaseSensitive(root, "args");
    int error = 2;
    if (!keys(root, fields, 4) || !request_id || strcmp(request_id, expected) || !name || !idem ||
        strlen(idem) > 128 || !strlen(idem) || !cJSON_IsObject(args))
        goto done;
    if (!strcmp(name, "tools/list") || !strcmp(name, "light.get") || !strcmp(name,"pdsh.task.next")) {
        if (busy) {
            error = 6;
            goto done;
        }
        if (cJSON_GetArraySize(args) != 0 || (!strcmp(name, "light.get") && !light_available) ||
            (!strcmp(name,"pdsh.task.next") && !pdsh_task_store_healthy()))
            goto done;
        memset(&readonly_result, 0, sizeof(readonly_result));
        readonly_result.magic = MAGIC;
        memcpy(readonly_result.id, id, 16);
        cJSON *result = !strcmp(name, "tools/list") ? tool_list() :
                        !strcmp(name,"pdsh.task.next") ? pdsh_task_store_next() : light_state();
        if (!result) { error = 11; goto done; }
        result_json(&readonly_result, "completed", result);
        *state = readonly_result.state;
        error = 0;
        upload.active = false;
        goto done;
    }
    if (!healthy) {
        error = 11;
        goto done;
    }
    if (busy) {
        error = 6;
        goto done;
    }
    if (!strcmp(name, "light.set")) {
        const char *const light_fields[] = {"on"};
        if (!light_available || !keys(args, light_fields, 1) || cJSON_GetArraySize(args) != 1 ||
            !cJSON_IsBool(cJSON_GetObjectItemCaseSensitive(args, "on")))
            goto done;
    } else if (!strcmp(name, "home.http")) {
        xl_home_request_t *r = calloc(1, sizeof(*r));
        bool valid = r && pdsh_home_parse(args, r);
        if (r) {
            memset(r, 0, sizeof(*r));
            free(r);
        }
        if (!valid)
            goto done;
    } else if ((!strcmp(name,"pdsh.task.accept") || !strcmp(name,"pdsh.task.complete") || !strcmp(name,"pdsh.task.fail")) && pdsh_task_store_healthy()) {
        /* The task store validates the exact arguments after durable Link intent. */
    } else {
        error = 14;
        goto done;
    }
    uint8_t hash[32], digest[32];
    if (!hash256((uint8_t *)idem, strlen(idem), hash) ||
        !hash256(upload.data, upload.total, digest)) {
        error = 11;
        goto done;
    }
    int slot = -1;
    for (int i = 0; i < RECEIPTS; i++) {
        if (receipts[i].magic != MAGIC) {
            if (slot < 0)
                slot = i;
            continue;
        }
        if (!memcmp(receipts[i].key, hash, 32)) {
            error = 5;
            goto done;
        }
    }
    if (slot < 0) {
        error = 15;
        goto done;
    }
    job_t *job = calloc(1, sizeof(*job));
    if (!job) {
        error = 11;
        goto done;
    }
    job->json = strdup((char *)upload.data);
    job->slot = slot;
    job->deadline = upload.deadline_ms * 1000;
    if (!job->json) {
        free(job);
        error = 11;
        goto done;
    }
    receipt_t *r = &receipts[slot];
    memset(r, 0, sizeof(*r));
    r->magic = MAGIC;
    r->state = 1;
    memcpy(r->id, id, 16);
    memcpy(r->key, hash, 32);
    memcpy(r->digest, digest, 32);
    // NVS commit is the point before which no GPIO or network operation is permitted.
    if (!save(slot)) {
        healthy = false;
        r->state = 3;
        free(job->json);
        free(job);
        error = 11;
        goto done;
    }
    busy = true;
    upload.active = false;
    if (xTaskCreate(execute, "pdsh_tool", 8192, job, 4, NULL) != pdPASS) {
        busy = false;
        r->state = 3;
        (void)save(slot);
        memset(job->json, 0, strlen(job->json));
        free(job->json);
        free(job);
    }
    *state = r->state;
    error = 0;
done:
    cJSON_Delete(root);
    if (!upload.active)
        memset(upload.data, 0, sizeof(upload.data));
    return error;
}
size_t tools_request(uint8_t op, const uint8_t *body, size_t n, uint8_t out[505]) {
    xSemaphoreTake(lock, portMAX_DELAY);
    size_t count = 1;
    out[0] = 2;
    if (op == PDSH_UPLOAD) {
        out[0] = pdsh_upload(&upload, body, n, now_ms());
        if (!out[0]) {
            out[1] = upload.used;
            out[2] = upload.used >> 8;
            count = 3;
        }
    } else if (op == PDSH_COMMIT && n == 16) {
        out[0] = commit(body, out + 1);
        if (!out[0])
            count = 2;
    } else if (op == PDSH_RESULT && n == 18) {
        receipt_t *r = NULL;
        for (int i = 0; i < RECEIPTS; i++)
            if (receipts[i].magic == MAGIC && !memcmp(receipts[i].id, body, 16))
                r = &receipts[i];
        if (!r && readonly_result.magic == MAGIC && !memcmp(readonly_result.id, body, 16))
            r = &readonly_result;
        uint16_t offset = u16(body + 16);
        memset(out, 0, 6);
        out[1] = r ? r->state : 0;
        count = 6;
        if (r && r->state == 2) {
            if (offset >= r->len) {
                out[0] = 5;
                count = 1;
            } else {
                size_t take = r->len - offset;
                if (take > 499)
                    take = 499;
                out[2] = r->len;
                out[3] = r->len >> 8;
                out[4] = offset;
                out[5] = offset >> 8;
                memcpy(out + 6, r->result + offset, take);
                count += take;
            }
        }
    }
    xSemaphoreGive(lock);
    return count;
}

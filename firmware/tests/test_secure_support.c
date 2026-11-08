// SPDX-License-Identifier: MIT
#include "test_secure_support.h"
#include <stdlib.h>
#include <string.h>

#define ENTRIES 32
typedef struct {
    char ns[16], key[16];
    size_t n;
    bool present, unreadable;
    uint8_t data[16384];
} entry_t;
static entry_t disk[ENTRIES], pending[ENTRIES];
static bool staged, fail_next;
static int commits;
static char namespaces[8][16];

static entry_t *find(entry_t *set, const char *ns, const char *key, bool create) {
    for (int i = 0; i < ENTRIES; i++)
        if (set[i].present && !strcmp(set[i].ns, ns) && !strcmp(set[i].key, key)) return &set[i];
    if (!create) return NULL;
    for (int i = 0; i < ENTRIES; i++)
        if (!set[i].present) {
            memset(&set[i], 0, sizeof(set[i]));
            snprintf(set[i].ns, sizeof(set[i].ns), "%s", ns);
            snprintf(set[i].key, sizeof(set[i].key), "%s", key);
            set[i].present = true;
            return &set[i];
        }
    abort();
}
static const char *ns_of(nvs_handle_t h) { return h >= 1 && h <= 8 ? namespaces[h - 1] : ""; }
void fake_nvs_reset(void) {
    memset(disk, 0, sizeof(disk));
    memset(pending, 0, sizeof(pending));
    memset(namespaces, 0, sizeof(namespaces));
    staged = fail_next = false;
    commits = 0;
}
void fake_nvs_put(const char *ns, const char *key, const void *data, size_t n) {
    entry_t *e = find(disk, ns, key, true);
    e->n = n;
    e->unreadable = false;
    memcpy(e->data, data, n);
}
void fake_nvs_unreadable(const char *ns, const char *key) { find(disk, ns, key, true)->unreadable = true; }
bool fake_nvs_get(const char *ns, const char *key, void *out, size_t *n) {
    entry_t *e = find(disk, ns, key, false);
    if (!e) return false;
    if (out) memcpy(out, e->data, e->n);
    *n = e->n;
    return true;
}
void fake_nvs_fail_next_commit(void) { fail_next = true; }
int fake_nvs_commits(void) { return commits; }

esp_err_t nvs_open(const char *name, int mode, nvs_handle_t *h) {
    (void)mode;
    for (unsigned i = 0; i < 8; i++)
        if (!namespaces[i][0] || !strcmp(namespaces[i], name)) {
            snprintf(namespaces[i], sizeof(namespaces[i]), "%s", name);
            *h = i + 1;
            return ESP_OK;
        }
    return ESP_FAIL;
}
esp_err_t nvs_close(nvs_handle_t h) {
    (void)h;
    return ESP_OK;
}
esp_err_t nvs_get_blob(nvs_handle_t h, const char *key, void *out, size_t *n) {
    entry_t *e = find(disk, ns_of(h), key, false);
    if (!e) return ESP_ERR_NVS_NOT_FOUND;
    if (e->unreadable) return ESP_FAIL;
    if (*n < e->n) return ESP_ERR_NVS_INVALID_LENGTH;
    memcpy(out, e->data, e->n);
    *n = e->n;
    return ESP_OK;
}
static void stage(void) {
    if (!staged) memcpy(pending, disk, sizeof(disk));
    staged = true;
}
esp_err_t nvs_set_blob(nvs_handle_t h, const char *key, const void *data, size_t n) {
    if (n > sizeof(disk[0].data)) return ESP_FAIL;
    stage();
    entry_t *e = find(pending, ns_of(h), key, true);
    e->n = n;
    e->unreadable = false;
    memcpy(e->data, data, n);
    return ESP_OK;
}
esp_err_t nvs_erase_key(nvs_handle_t h, const char *key) {
    stage();
    entry_t *e = find(pending, ns_of(h), key, false);
    if (!e) return ESP_ERR_NVS_NOT_FOUND;
    e->present = false;
    return ESP_OK;
}
esp_err_t nvs_get_u32(nvs_handle_t h, const char *key, uint32_t *out) {
    size_t n = 4;
    return nvs_get_blob(h, key, out, &n);
}
esp_err_t nvs_set_u32(nvs_handle_t h, const char *key, uint32_t value) { return nvs_set_blob(h, key, &value, 4); }
esp_err_t nvs_commit(nvs_handle_t h) {
    (void)h;
    if (fail_next) {
        fail_next = false;
        staged = false;
        return ESP_FAIL;
    }
    if (staged) memcpy(disk, pending, sizeof(disk));
    staged = false;
    commits++;
    return ESP_OK;
}

char *read_line(FILE *f) {
    size_t cap = 4096, n = 0;
    char *buf = malloc(cap);
    int c;
    while ((c = fgetc(f)) != EOF) {
        if (n + 2 >= cap) buf = realloc(buf, cap *= 2);
        if (c == '\n') break;
        buf[n++] = (char)c;
    }
    if (c == EOF && n == 0) {
        free(buf);
        return NULL;
    }
    buf[n] = 0;
    return buf;
}
size_t hex_bytes(const char *hex, uint8_t *out, size_t cap) {
    size_t n = strlen(hex) / 2;
    if (n > cap) abort();
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) abort();
        out[i] = (uint8_t)v;
    }
    return n;
}

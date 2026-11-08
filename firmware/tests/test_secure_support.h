// SPDX-License-Identifier: MIT
/* Host-test support for the secure-session tests: a namespace-aware fake NVS
 * with staged commits and injectable failures, JSONL and hex helpers. */
#pragma once
#include "test_platform.h"
#include <stdio.h>
esp_err_t nvs_close(nvs_handle_t);
esp_err_t nvs_erase_key(nvs_handle_t, const char *);

void fake_nvs_reset(void);
/* Sets a committed value directly (n bytes, no implicit NUL). */
void fake_nvs_put(const char *ns, const char *key, const void *data, size_t n);
/* Makes reads of ns/key fail with ESP_FAIL (an unreadable blob). */
void fake_nvs_unreadable(const char *ns, const char *key);
bool fake_nvs_get(const char *ns, const char *key, void *out, size_t *n);
/* The next nvs_commit fails and discards staged writes. */
void fake_nvs_fail_next_commit(void);
int fake_nvs_commits(void);

/* Reads one JSONL line (grows as needed); returns NULL at EOF. Caller frees. */
char *read_line(FILE *f);
size_t hex_bytes(const char *hex, uint8_t *out, size_t cap);
#define CHECK(cond, ...)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);                        \
            fprintf(stderr, __VA_ARGS__);                                                          \
            fprintf(stderr, "\n");                                                                 \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "cJSON.h"
void tools_init(uint32_t boot_id);
void tools_reset_upload(void);
void tools_set_task_profile(uint32_t app_caps);
// Caller serializes ctl messages. Each returns a legacy status byte as the first response byte.
size_t tools_request(uint8_t op, const uint8_t *body, size_t n, uint8_t out[505]);
const char *tools_device_id(void);
// A local producer submits a goal. False means not confirmed, including an
// uncertain storage failure; it does not prove that no task was stored.
bool tools_task_submit(const char *json);
// Returns an owned JSON value, or NULL for an unknown/unavailable task.
cJSON *tools_task_result(const char *id);

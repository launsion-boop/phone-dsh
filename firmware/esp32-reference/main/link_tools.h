// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
void tools_init(uint32_t boot_id);
void tools_reset_upload(void);
// Caller serializes ctl messages. Each returns a legacy status byte as the first response byte.
size_t tools_request(uint8_t op, const uint8_t *body, size_t n, uint8_t out[505]);
const char *tools_device_id(void);

// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define PDSH_MSG_MAX 512
#define PDSH_RPC_MAX 4096
#define PDSH_CAP_TOOLS (1UL << 20)
#define PDSH_APP_TOOLS (1UL << 10)
#define PDSH_APP_TASKS (1UL << 11)
static inline bool pdsh_task_capable(uint32_t caps) {
    return (caps & (PDSH_APP_TOOLS | PDSH_APP_TASKS)) == (PDSH_APP_TOOLS | PDSH_APP_TASKS);
}
#define PDSH_UPLOAD 0x54
#define PDSH_COMMIT 0x55
#define PDSH_RESULT 0x56
#define PDSH_EVENT 0x6c
uint16_t pdsh_crc(const uint8_t *p, size_t n);
size_t pdsh_frame(uint8_t op, uint16_t id, const uint8_t *body, size_t n,
                  uint8_t out[PDSH_MSG_MAX]);
// Returns legacy status BAD_LEN=2 or BAD_CRC=3, otherwise 0. No opcode reinterpretation.
int pdsh_decode(const uint8_t *p, size_t n, uint8_t *op, uint16_t *id, const uint8_t **body,
                size_t *len);
typedef struct {
    uint8_t data[PDSH_MSG_MAX];
    size_t len;
    bool active;
} pdsh_reassembly_t;
// 1 complete, 0 incomplete, -1 malformed (state cleared).
int pdsh_segment(pdsh_reassembly_t *r, const uint8_t *p, size_t n);
typedef struct {
    uint8_t id[16];
    uint8_t data[PDSH_RPC_MAX + 1];
    uint16_t total, used;
    uint32_t ttl_ms;
    uint64_t deadline_ms;
    bool active;
} pdsh_upload_t;
// UUID[16], total u16, offset u16, ttl_ms u32, chunk[<=481].
// Duplicate identical chunks do not extend the initial monotonic deadline.
int pdsh_upload(pdsh_upload_t *u, const uint8_t *p, size_t n, uint64_t now_ms);

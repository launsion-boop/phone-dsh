// SPDX-License-Identifier: MIT
#include "pdsh_link_wire.h"
#include <string.h>
static uint16_t le16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }
static uint32_t le32(const uint8_t *p) { return le16(p) | (uint32_t)le16(p + 2) << 16; }
uint16_t pdsh_crc(const uint8_t *p, size_t n) {
    uint16_t c = 0xffff;
    for (size_t i = 0; i < n; i++) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++)
            c = c & 0x8000 ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}
size_t pdsh_frame(uint8_t op, uint16_t id, const uint8_t *body, size_t n,
                  uint8_t out[PDSH_MSG_MAX]) {
    if (n > 505 || (n && !body))
        return 0;
    out[0] = op;
    out[1] = id;
    out[2] = id >> 8;
    out[3] = n;
    out[4] = n >> 8;
    if (n)
        memcpy(out + 5, body, n);
    uint16_t c = pdsh_crc(out, n + 5);
    out[n + 5] = c;
    out[n + 6] = c >> 8;
    return n + 7;
}
int pdsh_decode(const uint8_t *p, size_t n, uint8_t *op, uint16_t *id, const uint8_t **body,
                size_t *len) {
    if (n < 7 || n > 512 || le16(p + 3) != n - 7)
        return 2;
    if (pdsh_crc(p, n - 2) != le16(p + n - 2))
        return 3;
    *op = p[0];
    *id = le16(p + 1);
    *body = p + 5;
    *len = n - 7;
    return 0;
}
int pdsh_segment(pdsh_reassembly_t *r, const uint8_t *p, size_t n) {
    if (n < 2 || n > 244 || (p[0] & ~3))
        goto bad;
    if (p[0] & 2) {
        r->len = 0;
        r->active = true;
    }
    if (!r->active || n - 1 > PDSH_MSG_MAX - r->len)
        goto bad;
    memcpy(r->data + r->len, p + 1, n - 1);
    r->len += n - 1;
    if (p[0] & 1) {
        r->active = false;
        return 1;
    }
    return 0;
bad:
    r->active = false;
    r->len = 0;
    return -1;
}
int pdsh_upload(pdsh_upload_t *u, const uint8_t *p, size_t n, uint64_t now) {
    if (n < 25 || n > 505)
        return 2;
    uint16_t total = le16(p + 16), off = le16(p + 18);
    uint32_t ttl = le32(p + 20);
    size_t count = n - 24;
    if (!total || total > PDSH_RPC_MAX || off > total || count > total - off || ttl < 100 ||
        ttl > 30000)
        return 2;
    if (u->active && memcmp(u->id, p, 16) == 0) {
        if (now >= u->deadline_ms)
            return 9;
        if (u->total != total || u->ttl_ms != ttl)
            return 5;
    } else {
        if (u->active && now < u->deadline_ms)
            return 6;
        if (off)
            return 2;
        memset(u, 0, sizeof(*u));
        memcpy(u->id, p, 16);
        u->active = true;
        u->total = total;
        u->ttl_ms = ttl;
        u->deadline_ms = now + ttl;
    }
    if (off < u->used)
        return off + count <= u->used && !memcmp(u->data + off, p + 24, count) ? 0 : 5;
    if (off != u->used)
        return 2;
    memcpy(u->data + off, p + 24, count);
    u->used += count;
    u->data[u->used] = 0;
    return 0;
}

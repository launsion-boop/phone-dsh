// SPDX-License-Identifier: MIT
#include "pdsh_link_wire.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void vector(const char *name, uint8_t op, uint16_t id, const uint8_t *p, size_t n) {
    uint8_t frame[512];
    size_t size = pdsh_frame(op, id, p, n, frame);
    printf("{\"name\":\"%s\",\"hex\":\"", name);
    for (size_t i = 0; i < size; i++)
        printf("%02x", frame[i]);
    puts("\"}");
}
static void verify_file(const char *path, int valid) {
    FILE *file = fopen(path, "r");
    assert(file != NULL);
    char line[16384];
    unsigned count = 0;
    while (fgets(line, sizeof(line), file)) {
        const char *hex = strstr(line, "\"hex\":\"");
        assert(hex != NULL);
        hex += strlen("\"hex\":\"");
        const char *end = strchr(hex, '\"');
        assert(end != NULL && (end - hex) % 2 == 0);
        size_t length = (size_t)(end - hex) / 2;
        assert(length <= 512);
        uint8_t bytes[512], output[512], op;
        uint16_t id;
        const uint8_t *payload;
        size_t payload_len;
        for (size_t i = 0; i < length; i++) {
            unsigned value;
            assert(sscanf(hex + i * 2, "%2x", &value) == 1);
            bytes[i] = (uint8_t)value;
        }
        int result = pdsh_decode(bytes, length, &op, &id, &payload, &payload_len);
        if (valid) {
            assert(result == 0);
            assert(pdsh_frame(op, id, payload, payload_len, output) == length);
            assert(memcmp(bytes, output, length) == 0);
        } else {
            assert(result != 0);
        }
        count++;
    }
    assert(!ferror(file) && count > 0);
    fclose(file);
    printf("shared vectors %s: %u PASS\n", path, count);
}
int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--verify") == 0) {
        verify_file(argv[2], strcmp(argv[3], "valid") == 0);
        return 0;
    }
    uint8_t body[505] = {0}, frame[512];
    uint8_t op;
    uint16_t id;
    const uint8_t *payload;
    size_t n;
    assert(pdsh_frame(0x54, 17, body, 505, frame) == 512);
    assert(pdsh_decode(frame, 512, &op, &id, &payload, &n) == 0 && op == 0x54 && id == 17 &&
           n == 505);
    frame[511] ^= 1;
    assert(pdsh_decode(frame, 512, &op, &id, &payload, &n) == 3);
    assert(pdsh_decode(frame, 3, &op, &id, &payload, &n) == 2);
    pdsh_reassembly_t r = {0};
    uint8_t orphan[] = {1, 1};
    assert(pdsh_segment(&r, orphan, 2) == -1);
    uint8_t first[244] = {2};
    assert(pdsh_segment(&r, first, 244) == 0);
    assert(pdsh_segment(&r, first + 1, 243) == 0);
    assert(pdsh_segment(&r, first + 1, 243) == -1);
    pdsh_upload_t upload = {0};
    uint8_t packet[26] = {0};
    packet[15] = 1;
    packet[16] = 2;
    packet[20] = 100;
    packet[24] = '{';
    packet[25] = '}';
    assert(pdsh_upload(&upload, packet, 26, 1000) == 0 && upload.used == 2 &&
           upload.deadline_ms == 1100);
    assert(pdsh_upload(&upload, packet, 26, 1050) == 0 && upload.deadline_ms == 1100);
    packet[25] = 'x';
    assert(pdsh_upload(&upload, packet, 26, 1050) == 5);
    packet[25] = '}';
    assert(pdsh_upload(&upload, packet, 26, 1100) == 9);
    packet[15] = 2;
    assert(pdsh_upload(&upload, packet, 26, 1100) == 0 && upload.deadline_ms == 1200);
    if (argc > 1) {
        vector("tool_upload", 0x54, 0x1234, packet, sizeof(packet));
        vector("tool_commit", 0x55, 0x1235, packet, 16);
        uint8_t result[18] = {0};
        result[15] = 2;
        vector("tool_result", 0x56, 0x1236, result, 18);
        uint8_t ack[] = {0, 2, 0};
        vector("tool_upload_ack", 0xd4, 0x1234, ack, 3);
        uint8_t hello[] = {2, 1, 0, 4, 0, 0};
        vector("hello_pdsh", 1, 1, hello, 6);
    } else
        puts("link wire: CRC, bounds, reassembly, upload conflict and monotonic deadline PASS");
    return 0;
}

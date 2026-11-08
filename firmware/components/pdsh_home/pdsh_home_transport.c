// SPDX-License-Identifier: MIT
#include "esp_heap_caps.h"

// The upstream appliance stores all control state in PSRAM. A generic BLE
// peripheral need not initialize PSRAM: these tiny socket/DNS contexts fit in
// internal byte-addressable RAM. Keep upstream wire/deadline/socket code intact.
static void *pdsh_home_control_calloc(size_t count, size_t size, uint32_t requested_caps) {
    (void)requested_caps;
    return heap_caps_calloc(count, size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
}
#define heap_caps_calloc pdsh_home_control_calloc
#include "vendor/xl_home_transport.c"
#undef heap_caps_calloc

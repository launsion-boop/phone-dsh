#pragma once

#include <stdint.h>

#include "esp_err.h"
#include "esp_transport.h"

/* Resolves on the lwIP thread without letting DNS retries retain the worker.
 * The accepted address is network byte order and must be private IPv4. */
esp_err_t xl_home_resolve_private_ipv4(const char *host,
                                         int64_t deadline_us,
                                         uint32_t *out_be);

/* Plain TCP for an already validated IPv4 literal. Every connect/read/write
 * shares this absolute esp_timer deadline, including loops inside the HTTP
 * client. The caller owns the handle: destroy it AFTER HTTP client cleanup. */
esp_transport_handle_t xl_home_transport_create(int64_t deadline_us);

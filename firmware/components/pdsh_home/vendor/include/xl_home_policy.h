#pragma once

/*
 * Pure validation for the `home.http` device command (xiaozhi-link.home.v1).
 *
 * No ESP-IDF, lwIP or cJSON dependency and no dynamic allocation, so the
 * whole policy is host-testable. The device trusts only these checks: the
 * cloud may ask for one bounded plain-HTTP request against a private-network
 * host and nothing else.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XL_HOME_URL_MAX_BYTES 256U
#define XL_HOME_HOST_MAX_BYTES 63U
/* URL budget minus "http://" and the shortest (one-byte) host. */
#define XL_HOME_PATH_MAX_BYTES 248U
#define XL_HOME_HEADER_MAX_COUNT 4U
#define XL_HOME_HEADER_NAME_MAX_BYTES 32U
#define XL_HOME_HEADER_VALUE_MAX_BYTES 160U
#define XL_HOME_REQUEST_BODY_MAX_BYTES 768U
#define XL_HOME_TIMEOUT_DEFAULT_MS 5000U
#define XL_HOME_TIMEOUT_MIN_MS 1000U
#define XL_HOME_TIMEOUT_MAX_MS 10000U

/* The only failure reason the policy reports (closed server-side set). */
#define XL_HOME_REASON_INVALID_ARGUMENT "invalid_argument"

typedef struct {
    char method[8];
    char host[XL_HOME_HOST_MAX_BYTES + 1U];
    uint16_t port;
    /* Origin-form request target: always starts with '/'. */
    char path[XL_HOME_PATH_MAX_BYTES + 1U];
    /* false: host is a `.local` or single-label name that the worker must
     * resolve and re-check with xl_home_ipv4_private(). */
    bool host_is_ipv4;
    /* Network byte order, same memory layout as struct in_addr.s_addr. */
    uint32_t ipv4_be;
    char header_names[XL_HOME_HEADER_MAX_COUNT]
                     [XL_HOME_HEADER_NAME_MAX_BYTES + 1U];
    char header_values[XL_HOME_HEADER_MAX_COUNT]
                      [XL_HOME_HEADER_VALUE_MAX_BYTES + 1U];
    uint8_t header_count;
    char body[XL_HOME_REQUEST_BODY_MAX_BYTES + 1U];
    uint16_t body_len;
    uint32_t timeout_ms;
    /* Set by the caller, not parsed: the maximum JSON-escaped bytes the
     * response body may occupy in the uplink command_result frame. */
    uint16_t response_json_budget;
} xl_home_request_t;

/* Callers start from a zeroed request; each step fills its own fields. */

/** Exact, case-sensitive GET / POST / PUT / PATCH / DELETE. */
bool xl_home_policy_method(const char *method);

/**
 * Accepts `http://host[:port][/path]` of at most 256 printable ASCII bytes
 * without whitespace or userinfo. host is a dotted-quad private IPv4 literal
 * (10/8, 172.16/12, 192.168/16, 169.254/16), a `*.local` name or a single
 * label. IPv6 literals and numeric single labels are rejected.
 */
bool xl_home_policy_parse_url(const char *url, xl_home_request_t *out,
                                  const char **reason);

/**
 * Appends one header: at most four, unique case-insensitively, name of 1..32
 * RFC 9110 token characters, value of 0..160 bytes in 0x20..0x7e. Host,
 * Content-Length and Transfer-Encoding are reserved for the HTTP client.
 */
bool xl_home_policy_header(const char *name, const char *value,
                               xl_home_request_t *out,
                               const char **reason);

/** At most 768 bytes without NUL; GET and DELETE must not carry a body. */
bool xl_home_policy_body(const char *body, size_t len, const char *method,
                             xl_home_request_t *out, const char **reason);

/** 10/8, 172.16/12, 192.168/16 or 169.254/16; `be` as in in_addr.s_addr. */
bool xl_home_ipv4_private(uint32_t be);

/**
 * Makes a response body safe for one JSON string: keeps at most `cap` bytes,
 * drops a multi-byte sequence cut by the limit (or by an early end of data),
 * replaces invalid UTF-8 bytes and C0 controls other than TAB/LF/CR
 * (including NUL) with '?', and NUL-terminates. The control replacement keeps
 * the body a C string and bounds JSON escaping to two bytes per input byte.
 * `buf` must hold at least min(len, cap) + 1 bytes. Returns the new length.
 */
size_t xl_home_utf8_sanitize(char *buf, size_t len, size_t cap);

/**
 * Longest prefix of `text`, ending on a UTF-8 character boundary, whose
 * cJSON string escaping needs at most `escaped_budget` bytes (quotes not
 * counted).
 */
size_t xl_home_json_fit(const char *text, size_t len,
                            size_t escaped_budget);

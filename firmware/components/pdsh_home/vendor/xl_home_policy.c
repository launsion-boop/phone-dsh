#include "xl_home_policy.h"

#include <string.h>

static bool reject(const char **reason)
{
    if (reason != NULL) {
        *reason = XL_HOME_REASON_INVALID_ARGUMENT;
    }
    return false;
}

static bool is_digit(char c)
{
    return c >= '0' && c <= '9';
}

static bool is_alpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static char lower_ascii(char c)
{
    return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

static bool equals_ignore_case(const char *left, const char *right)
{
    while (*left != '\0' && *right != '\0') {
        if (lower_ascii(*left) != lower_ascii(*right)) {
            return false;
        }
        ++left;
        ++right;
    }
    return *left == *right;
}

/* strnlen() is POSIX, not C11. */
static size_t bounded_length(const char *text, size_t limit)
{
    size_t length = 0U;
    while (length < limit && text[length] != '\0') {
        ++length;
    }
    return length;
}

/* RFC 9110 token character. */
static bool is_tchar(char c)
{
    return is_digit(c) || is_alpha(c) ||
           (c != '\0' && strchr("!#$%&'*+-.^_`|~", c) != NULL);
}

bool xl_home_policy_method(const char *method)
{
    static const char *const allowed[] = {
        "GET", "POST", "PUT", "PATCH", "DELETE",
    };
    if (method == NULL) {
        return false;
    }
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]);
         ++index) {
        if (strcmp(method, allowed[index]) == 0) {
            return true;
        }
    }
    return false;
}

bool xl_home_ipv4_private(uint32_t be)
{
    uint8_t octet[4];
    memcpy(octet, &be, sizeof(octet));
    return octet[0] == 10U ||
           (octet[0] == 172U && (octet[1] & 0xF0U) == 16U) ||
           (octet[0] == 192U && octet[1] == 168U) ||
           (octet[0] == 169U && octet[1] == 254U);
}

/* Strict dotted quad: no leading zeros (inet_aton reads them as octal), no
 * shortened or integer forms. */
static bool parse_dotted_quad(const char *host, size_t length,
                              uint8_t octets[4])
{
    size_t index = 0U;
    for (size_t part = 0U; part < 4U; ++part) {
        if (part > 0U) {
            if (index >= length || host[index] != '.') {
                return false;
            }
            ++index;
        }
        const size_t start = index;
        unsigned int value = 0U;
        while (index < length && is_digit(host[index]) &&
               index - start < 3U) {
            value = value * 10U + (unsigned int)(host[index] - '0');
            ++index;
        }
        const size_t digits = index - start;
        if (digits == 0U || value > 255U ||
            (digits > 1U && host[start] == '0')) {
            return false;
        }
        octets[part] = (uint8_t)value;
    }
    return index == length;
}

/* LDH labels; either one label or a name whose last label is "local". */
static bool valid_home_hostname(const char *host, size_t length)
{
    size_t label_start = 0U;
    size_t labels = 0U;
    for (size_t index = 0U; index <= length; ++index) {
        if (index == length || host[index] == '.') {
            const size_t label_length = index - label_start;
            if (label_length == 0U || label_length > 63U) {
                return false;
            }
            ++labels;
            label_start = index + 1U;
            continue;
        }
        if (!is_digit(host[index]) && !is_alpha(host[index]) &&
            host[index] != '-') {
            return false;
        }
    }
    if (labels == 1U) {
        return true;
    }
    static const char suffix[] = ".local";
    const size_t suffix_length = sizeof(suffix) - 1U;
    if (length <= suffix_length) {
        return false;
    }
    for (size_t index = 0U; index < suffix_length; ++index) {
        if (lower_ascii(host[length - suffix_length + index]) !=
            suffix[index]) {
            return false;
        }
    }
    return true;
}

bool xl_home_policy_parse_url(const char *url, xl_home_request_t *out,
                                  const char **reason)
{
    static const char scheme[] = "http://";
    const size_t scheme_length = sizeof(scheme) - 1U;
    if (url == NULL || out == NULL) {
        return reject(reason);
    }
    const size_t url_length =
        bounded_length(url, XL_HOME_URL_MAX_BYTES + 1U);
    if (url_length > XL_HOME_URL_MAX_BYTES ||
        strncmp(url, scheme, scheme_length) != 0) {
        return reject(reason);
    }
    for (size_t index = 0U; index < url_length; ++index) {
        const unsigned char byte = (unsigned char)url[index];
        if (byte <= 0x20U || byte >= 0x7FU) {
            return reject(reason);
        }
    }

    const char *authority = url + scheme_length;
    const char *url_end = url + url_length;
    const char *authority_end = authority;
    while (authority_end < url_end && *authority_end != '/' &&
           *authority_end != '?' && *authority_end != '#') {
        if (*authority_end == '@' || *authority_end == '[' ||
            *authority_end == ']') {
            return reject(reason);
        }
        ++authority_end;
    }
    const char *host_end = authority;
    while (host_end < authority_end && *host_end != ':') {
        ++host_end;
    }
    const size_t host_length = (size_t)(host_end - authority);
    if (host_length == 0U || host_length > XL_HOME_HOST_MAX_BYTES) {
        return reject(reason);
    }

    unsigned long port = 80UL;
    if (host_end < authority_end) {
        const char *cursor = host_end + 1;
        size_t digits = 0U;
        port = 0UL;
        while (cursor < authority_end && is_digit(*cursor) && digits < 5U) {
            port = port * 10UL + (unsigned long)(*cursor - '0');
            ++digits;
            ++cursor;
        }
        if (digits == 0U || cursor != authority_end || port == 0UL ||
            port > 65535UL) {
            return reject(reason);
        }
    }

    const size_t rest_length = (size_t)(url_end - authority_end);
    const bool needs_slash = rest_length == 0U || *authority_end != '/';
    if (rest_length + (needs_slash ? 1U : 0U) > XL_HOME_PATH_MAX_BYTES) {
        return reject(reason);
    }

    bool numeric = true;
    for (size_t index = 0U; index < host_length; ++index) {
        if (!is_digit(authority[index]) && authority[index] != '.') {
            numeric = false;
            break;
        }
    }
    uint32_t ipv4_be = 0U;
    if (numeric) {
        uint8_t octets[4];
        if (!parse_dotted_quad(authority, host_length, octets)) {
            return reject(reason);
        }
        memcpy(&ipv4_be, octets, sizeof(ipv4_be));
        if (!xl_home_ipv4_private(ipv4_be)) {
            return reject(reason);
        }
    } else if (!valid_home_hostname(authority, host_length)) {
        return reject(reason);
    }

    memcpy(out->host, authority, host_length);
    out->host[host_length] = '\0';
    out->port = (uint16_t)port;
    out->host_is_ipv4 = numeric;
    out->ipv4_be = ipv4_be;
    size_t path_length = 0U;
    if (needs_slash) {
        out->path[path_length++] = '/';
    }
    memcpy(out->path + path_length, authority_end, rest_length);
    out->path[path_length + rest_length] = '\0';
    return true;
}

bool xl_home_policy_header(const char *name, const char *value,
                               xl_home_request_t *out,
                               const char **reason)
{
    static const char *const reserved[] = {
        "host", "content-length", "transfer-encoding",
    };
    if (name == NULL || value == NULL || out == NULL ||
        out->header_count >= XL_HOME_HEADER_MAX_COUNT) {
        return reject(reason);
    }
    const size_t name_length =
        bounded_length(name, XL_HOME_HEADER_NAME_MAX_BYTES + 1U);
    if (name_length == 0U || name_length > XL_HOME_HEADER_NAME_MAX_BYTES) {
        return reject(reason);
    }
    for (size_t index = 0U; index < name_length; ++index) {
        if (!is_tchar(name[index])) {
            return reject(reason);
        }
    }
    for (size_t index = 0U; index < sizeof(reserved) / sizeof(reserved[0]);
         ++index) {
        if (equals_ignore_case(name, reserved[index])) {
            return reject(reason);
        }
    }
    for (size_t index = 0U; index < out->header_count; ++index) {
        if (equals_ignore_case(name, out->header_names[index])) {
            return reject(reason);
        }
    }
    const size_t value_length =
        bounded_length(value, XL_HOME_HEADER_VALUE_MAX_BYTES + 1U);
    if (value_length > XL_HOME_HEADER_VALUE_MAX_BYTES) {
        return reject(reason);
    }
    for (size_t index = 0U; index < value_length; ++index) {
        const unsigned char byte = (unsigned char)value[index];
        if (byte < 0x20U || byte > 0x7EU) {
            return reject(reason);
        }
    }
    const uint8_t slot = out->header_count;
    memcpy(out->header_names[slot], name, name_length + 1U);
    memcpy(out->header_values[slot], value, value_length + 1U);
    out->header_count = (uint8_t)(slot + 1U);
    return true;
}

bool xl_home_policy_body(const char *body, size_t len, const char *method,
                             xl_home_request_t *out, const char **reason)
{
    if (out == NULL || method == NULL || (body == NULL && len > 0U) ||
        len > XL_HOME_REQUEST_BODY_MAX_BYTES) {
        return reject(reason);
    }
    if (len > 0U &&
        (strcmp(method, "GET") == 0 || strcmp(method, "DELETE") == 0 ||
         memchr(body, '\0', len) != NULL)) {
        return reject(reason);
    }
    if (len > 0U) {
        memcpy(out->body, body, len);
    }
    out->body[len] = '\0';
    out->body_len = (uint16_t)len;
    return true;
}

static size_t utf8_sequence_length(unsigned char lead)
{
    if (lead < 0x80U) return 1U;
    if (lead >= 0xC2U && lead <= 0xDFU) return 2U;
    if (lead >= 0xE0U && lead <= 0xEFU) return 3U;
    if (lead >= 0xF0U && lead <= 0xF4U) return 4U;
    /* Continuation byte, overlong C0/C1 lead or beyond U+10FFFF. */
    return 0U;
}

static bool utf8_continuation_valid(unsigned char lead, size_t position,
                                    unsigned char byte)
{
    if ((byte & 0xC0U) != 0x80U) {
        return false;
    }
    if (position != 1U) {
        return true;
    }
    switch (lead) {
    case 0xE0U: return byte >= 0xA0U; /* overlong */
    case 0xEDU: return byte <= 0x9FU; /* UTF-16 surrogates */
    case 0xF0U: return byte >= 0x90U; /* overlong */
    case 0xF4U: return byte <= 0x8FU; /* beyond U+10FFFF */
    default: return true;
    }
}

size_t xl_home_utf8_sanitize(char *buf, size_t len, size_t cap)
{
    if (buf == NULL) {
        return 0U;
    }
    size_t length = len < cap ? len : cap;
    size_t index = 0U;
    while (index < length) {
        const unsigned char lead = (unsigned char)buf[index];
        if (lead < 0x80U) {
            if (lead < 0x20U && lead != '\t' && lead != '\n' &&
                lead != '\r') {
                buf[index] = '?';
            }
            ++index;
            continue;
        }
        const size_t expected = utf8_sequence_length(lead);
        size_t valid = expected == 0U ? 0U : 1U;
        while (valid < expected && index + valid < length &&
               utf8_continuation_valid(
                   lead, valid, (unsigned char)buf[index + valid])) {
            ++valid;
        }
        if (expected != 0U && valid == expected) {
            index += expected;
            continue;
        }
        if (expected != 0U && index + valid == length) {
            /* A well-formed prefix cut by the limit or the end of data. */
            length = index;
            break;
        }
        buf[index] = '?';
        ++index;
    }
    buf[length] = '\0';
    return length;
}

/* Bytes cJSON's print_string_ptr() emits for one input byte. */
static size_t json_escape_cost(unsigned char byte)
{
    switch (byte) {
    case '"':
    case '\\':
    case '\b':
    case '\f':
    case '\n':
    case '\r':
    case '\t':
        return 2U;
    default:
        return byte < 0x20U ? 6U : 1U;
    }
}

size_t xl_home_json_fit(const char *text, size_t len,
                            size_t escaped_budget)
{
    if (text == NULL) {
        return 0U;
    }
    size_t index = 0U;
    size_t used = 0U;
    while (index < len) {
        const unsigned char lead = (unsigned char)text[index];
        size_t width = 1U;
        size_t cost = json_escape_cost(lead);
        if (lead >= 0x80U) {
            width = utf8_sequence_length(lead);
            if (width == 0U) {
                width = 1U;
            }
            cost = width;
        }
        if (index + width > len || used + cost > escaped_budget) {
            break;
        }
        index += width;
        used += cost;
    }
    return index;
}

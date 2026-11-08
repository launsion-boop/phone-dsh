#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "xl_home_policy.h"

static uint32_t ipv4_be(uint8_t a, uint8_t b, uint8_t c, uint8_t d)
{
    const uint8_t octets[4] = {a, b, c, d};
    uint32_t be = 0U;
    memcpy(&be, octets, sizeof(be));
    return be;
}

/* Takes the address so the reason is read after the call has set it. */
static void expect_reason(bool ok, const char *const *reason)
{
    assert(!ok);
    assert(*reason != NULL &&
           strcmp(*reason, XL_HOME_REASON_INVALID_ARGUMENT) == 0);
}

/* The frozen downlink frame of tono.main-home.v1 Appendix A must pass. */
static void test_appendix_a_frame_and_methods(void)
{
    xl_home_request_t request = {0};
    const char *reason = NULL;
    assert(xl_home_policy_method("POST"));
    assert(xl_home_policy_parse_url(
        "http://192.168.1.50:8123/api/services/light/turn_on", &request,
        &reason));
    assert(request.host_is_ipv4);
    assert(request.ipv4_be == ipv4_be(192, 168, 1, 50));
    assert(strcmp(request.host, "192.168.1.50") == 0);
    assert(request.port == 8123U);
    assert(strcmp(request.path, "/api/services/light/turn_on") == 0);
    assert(xl_home_policy_header("Authorization", "Bearer example-token",
                                     &request, &reason));
    assert(xl_home_policy_header("Content-Type", "application/json",
                                     &request, &reason));
    static const char body[] = "{\"entity_id\":\"light.living_room\"}";
    assert(xl_home_policy_body(body, sizeof(body) - 1U, "POST", &request,
                                   &reason));
    assert(request.header_count == 2U);
    assert(request.body_len == sizeof(body) - 1U);
    assert(strcmp(request.body, body) == 0);

    static const struct {
        const char *method;
        bool ok;
    } methods[] = {
        {"GET", true}, {"POST", true}, {"PUT", true}, {"PATCH", true},
        {"DELETE", true}, {"get", false}, {"HEAD", false},
        {"OPTIONS", false}, {"", false}, {"POSTX", false}, {NULL, false},
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); ++i) {
        assert(xl_home_policy_method(methods[i].method) == methods[i].ok);
    }
}

static void test_url_rules(void)
{
    char long_url[XL_HOME_URL_MAX_BYTES + 2U];
    static const char prefix[] = "http://10.0.0.2/";
    memcpy(long_url, prefix, sizeof(prefix) - 1U);
    memset(long_url + sizeof(prefix) - 1U, 'a',
           XL_HOME_URL_MAX_BYTES - (sizeof(prefix) - 1U));
    long_url[XL_HOME_URL_MAX_BYTES] = '\0';
    char too_long_url[sizeof(long_url)];
    memcpy(too_long_url, long_url, XL_HOME_URL_MAX_BYTES);
    too_long_url[XL_HOME_URL_MAX_BYTES] = 'a';
    too_long_url[XL_HOME_URL_MAX_BYTES + 1U] = '\0';

    static const struct {
        const char *url;
        bool ok;
        bool ipv4;
        uint16_t port;
        const char *host;
        const char *path;
    } cases[] = {
        {"http://10.0.0.2", true, true, 80, "10.0.0.2", "/"},
        {"http://172.16.0.1:1/x?y=1", true, true, 1, "172.16.0.1", "/x?y=1"},
        {"http://172.31.255.255:65535?q", true, true, 65535,
         "172.31.255.255", "/?q"},
        {"http://169.254.10.20/", true, true, 80, "169.254.10.20", "/"},
        {"http://ha.local/api", true, false, 80, "ha.local", "/api"},
        {"http://HomeAssistant.LOCAL:8123", true, false, 8123,
         "HomeAssistant.LOCAL", "/"},
        {"http://homeassistant/", true, false, 80, "homeassistant", "/"},
        /* Public, loopback and edge-of-range addresses. */
        {"http://8.8.8.8/", false, false, 0, NULL, NULL},
        {"http://127.0.0.1/", false, false, 0, NULL, NULL},
        {"http://172.32.0.1/", false, false, 0, NULL, NULL},
        {"http://172.15.255.255/", false, false, 0, NULL, NULL},
        {"http://192.169.0.1/", false, false, 0, NULL, NULL},
        /* Scheme, userinfo, whitespace, IPv6 and ambiguous numeric hosts. */
        {"https://192.168.1.2/", false, false, 0, NULL, NULL},
        {"HTTP://192.168.1.2/", false, false, 0, NULL, NULL},
        {"http://user:pw@192.168.1.2/", false, false, 0, NULL, NULL},
        {"http://192.168.1.2@8.8.8.8/", false, false, 0, NULL, NULL},
        {"http://192.168.1.2/a b", false, false, 0, NULL, NULL},
        {"http://192.168.1.2/\t", false, false, 0, NULL, NULL},
        {"http://192.168.1.2/\xC3\xA9", false, false, 0, NULL, NULL},
        {"http://[fe80::1]/", false, false, 0, NULL, NULL},
        {"http://192.168.01.2/", false, false, 0, NULL, NULL},
        {"http://192.168.1/", false, false, 0, NULL, NULL},
        {"http://3232235777/", false, false, 0, NULL, NULL},
        {"http://example.com/", false, false, 0, NULL, NULL},
        {"http://ha..local/", false, false, 0, NULL, NULL},
        {"http://ha_1.local/", false, false, 0, NULL, NULL},
        {"http:///path", false, false, 0, NULL, NULL},
        /* Ports. */
        {"http://192.168.1.2:0/", false, false, 0, NULL, NULL},
        {"http://192.168.1.2:65536/", false, false, 0, NULL, NULL},
        {"http://192.168.1.2:/", false, false, 0, NULL, NULL},
        {"http://192.168.1.2:80a/", false, false, 0, NULL, NULL},
        {"http://192.168.1.2:123456/", false, false, 0, NULL, NULL},
        {"", false, false, 0, NULL, NULL},
        {NULL, false, false, 0, NULL, NULL},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        xl_home_request_t request = {0};
        const char *reason = NULL;
        const bool ok =
            xl_home_policy_parse_url(cases[i].url, &request, &reason);
        if (ok != cases[i].ok) {
            fprintf(stderr, "url case %zu: %s\n", i,
                    cases[i].url != NULL ? cases[i].url : "(null)");
        }
        if (!cases[i].ok) {
            expect_reason(ok, &reason);
            continue;
        }
        assert(ok);
        assert(request.host_is_ipv4 == cases[i].ipv4);
        assert(request.port == cases[i].port);
        assert(strcmp(request.host, cases[i].host) == 0);
        assert(strcmp(request.path, cases[i].path) == 0);
    }

    xl_home_request_t request = {0};
    const char *reason = NULL;
    assert(xl_home_policy_parse_url(long_url, &request, &reason));
    assert(strlen(request.path) == XL_HOME_URL_MAX_BYTES -
                                       (sizeof("http://10.0.0.2") - 1U));
    reason = NULL;
    expect_reason(
        xl_home_policy_parse_url(too_long_url, &request, &reason),
        &reason);

    /* The same rule re-checks addresses a hostname resolved to. */
    assert(xl_home_ipv4_private(ipv4_be(10, 255, 255, 255)));
    assert(xl_home_ipv4_private(ipv4_be(192, 168, 0, 0)));
    assert(!xl_home_ipv4_private(ipv4_be(0, 0, 0, 0)));
    assert(!xl_home_ipv4_private(ipv4_be(11, 0, 0, 1)));
    assert(!xl_home_ipv4_private(ipv4_be(169, 253, 1, 1)));
    assert(!xl_home_ipv4_private(ipv4_be(255, 255, 255, 255)));
}

static void test_header_rules(void)
{
    char name_33[34];
    memset(name_33, 'x', 33U);
    name_33[33] = '\0';
    char value_160[161];
    memset(value_160, 'v', 160U);
    value_160[160] = '\0';
    char value_161[162];
    memset(value_161, 'v', 161U);
    value_161[161] = '\0';

    static const struct {
        const char *name;
        const char *value;
    } rejected[] = {
        {"Host", "192.168.1.9"},
        {"content-length", "0"},
        {"TRANSFER-ENCODING", "chunked"},
        {"X-Ok", "a\r\nInjected: 1"},
        {"X-Ok", "a\nb"},
        {"X-Ok", "tab\there"},
        {"X-Ok", "\xC3\xA9"},
        {"X\r\nInjected", "1"},
        {"Bad Name", "1"},
        {"a:b", "1"},
        {"", "1"},
        {"authorization", "duplicate"},
    };
    xl_home_request_t request = {0};
    const char *reason = NULL;
    assert(xl_home_policy_header("Authorization", "Bearer t", &request,
                                     &reason));
    for (size_t i = 0; i < sizeof(rejected) / sizeof(rejected[0]); ++i) {
        reason = NULL;
        expect_reason(xl_home_policy_header(rejected[i].name,
                                                rejected[i].value, &request,
                                                &reason),
                      &reason);
    }
    reason = NULL;
    expect_reason(xl_home_policy_header(name_33, "1", &request, &reason),
                  &reason);
    reason = NULL;
    expect_reason(
        xl_home_policy_header("X-Long", value_161, &request, &reason),
        &reason);
    assert(request.header_count == 1U);

    assert(xl_home_policy_header(name_33 + 1, "", &request, &reason));
    assert(xl_home_policy_header("X-Value", value_160, &request,
                                     &reason));
    assert(xl_home_policy_header("Accept", "*/*", &request, &reason));
    assert(request.header_count == XL_HOME_HEADER_MAX_COUNT);
    reason = NULL;
    expect_reason(
        xl_home_policy_header("X-Fifth", "1", &request, &reason), &reason);
    assert(strcmp(request.header_values[2], value_160) == 0);
}

static void test_body_rules(void)
{
    char body[XL_HOME_REQUEST_BODY_MAX_BYTES + 1U];
    memset(body, 'b', sizeof(body));
    static const struct {
        size_t len;
        const char *method;
        bool ok;
    } cases[] = {
        {XL_HOME_REQUEST_BODY_MAX_BYTES, "POST", true},
        {XL_HOME_REQUEST_BODY_MAX_BYTES + 1U, "POST", false},
        {1U, "PUT", true},
        {1U, "PATCH", true},
        {0U, "GET", true},
        {0U, "DELETE", true},
        {1U, "GET", false},
        {1U, "DELETE", false},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        xl_home_request_t request = {0};
        const char *reason = NULL;
        const bool ok = xl_home_policy_body(body, cases[i].len,
                                                cases[i].method, &request,
                                                &reason);
        if (!cases[i].ok) {
            expect_reason(ok, &reason);
            continue;
        }
        assert(ok);
        assert(request.body_len == cases[i].len);
        assert(request.body[cases[i].len] == '\0');
    }
    xl_home_request_t request = {0};
    const char *reason = NULL;
    expect_reason(xl_home_policy_body("a\0b", 3U, "POST", &request,
                                          &reason),
                  &reason);
}

/* Response bodies go into one JSON string of a <= 4096-byte frame. */
static void test_response_body_sanitize_and_fit(void)
{
    static const struct {
        const char *input;
        size_t len;
        size_t cap;
        const char *output;
    } cases[] = {
        {"plain", 5U, 16U, "plain"},
        /* Multi-byte characters are never split by the cap. */
        {"a\xC3\xA9", 3U, 2U, "a"},
        {"ab\xE2\x82\xAC", 5U, 4U, "ab"},
        {"\xF0\x9F\x98\x80z", 5U, 5U, "\xF0\x9F\x98\x80z"},
        /* A sequence cut by the end of the read is dropped, not replaced. */
        {"ok\xE2\x82", 4U, 16U, "ok"},
        /* Invalid bytes become '?'. */
        {"\xFFx", 2U, 16U, "?x"},
        {"\x80", 1U, 16U, "?"},
        {"\xC0\xAF", 2U, 16U, "??"},
        {"\xED\xA0\x80", 3U, 16U, "???"},
        {"\xF4\x90\x80\x80", 4U, 16U, "????"},
        /* Controls other than TAB/LF/CR, NUL included, become '?'. */
        {"a\x01\0b\t\n\r", 7U, 16U, "a??b\t\n\r"},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        char buffer[32];
        memcpy(buffer, cases[i].input, cases[i].len);
        const size_t length =
            xl_home_utf8_sanitize(buffer, cases[i].len, cases[i].cap);
        assert(length == strlen(cases[i].output));
        assert(memcmp(buffer, cases[i].output, length + 1U) == 0);
    }

    /* Escaping matches cJSON: quote/backslash/LF cost 2, other C0 cost 6. */
    assert(xl_home_json_fit("a\"b", 3U, 3U) == 2U);
    assert(xl_home_json_fit("a\"b", 3U, 4U) == 3U);
    assert(xl_home_json_fit("\\\n", 2U, 3U) == 1U);
    assert(xl_home_json_fit("\x01x", 2U, 5U) == 0U);
    assert(xl_home_json_fit("x\xC3\xA9y", 4U, 2U) == 1U);
    assert(xl_home_json_fit("x\xC3\xA9y", 4U, 3U) == 3U);
    assert(xl_home_json_fit("x\xC3", 2U, 16U) == 1U);
}

int main(void)
{
    test_appendix_a_frame_and_methods();
    test_url_rules();
    test_header_rules();
    test_body_rules();
    test_response_body_sanitize_and_fit();
    puts("xl_home_policy_host_test: ok");
    return 0;
}

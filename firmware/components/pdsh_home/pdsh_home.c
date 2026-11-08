// SPDX-License-Identifier: MIT
#include "pdsh_home.h"
#include "esp_http_client.h"
#include "esp_timer.h"
#include "sdkconfig.h"
#include "xl_home_transport.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static const char *text(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool allowed_keys(const cJSON *o) {
    if (!cJSON_IsObject(o))
        return false;
    const cJSON *v;
    cJSON_ArrayForEach(v, o) {
        if (!v->string)
            return false;
        if (strcmp(v->string, "method") && strcmp(v->string, "url") &&
            strcmp(v->string, "headers") && strcmp(v->string, "body") &&
            strcmp(v->string, "timeout_ms"))
            return false;
        for (const cJSON *other = v->next; other; other = other->next)
            if (other->string && !strcmp(other->string, v->string))
                return false;
    }
    return true;
}
bool pdsh_home_parse(const cJSON *args, xl_home_request_t *r) {
    memset(r, 0, sizeof(*r));
    const char *method = text(args, "method"), *url = text(args, "url");
    xl_home_request_t allowed = {0};
    if (!allowed_keys(args) || !method || !url || !xl_home_policy_method(method) ||
        !xl_home_policy_parse_url(url, r, NULL) || !r->host_is_ipv4 ||
        !xl_home_policy_parse_url(CONFIG_PDSH_HOME_ORIGIN, &allowed, NULL) ||
        !allowed.host_is_ipv4 || strcmp(allowed.path, "/") || allowed.port != r->port ||
        allowed.ipv4_be != r->ipv4_be)
        return false;
    strcpy(r->method, method);
    r->timeout_ms = 5000;
    const cJSON *timeout = cJSON_GetObjectItemCaseSensitive(args, "timeout_ms");
    if (timeout) {
        if (!cJSON_IsNumber(timeout) || !isfinite(timeout->valuedouble) ||
            floor(timeout->valuedouble) != timeout->valuedouble || timeout->valuedouble < 1000 ||
            timeout->valuedouble > 10000)
            return false;
        r->timeout_ms = (uint32_t)timeout->valuedouble;
    }
    const cJSON *headers = cJSON_GetObjectItemCaseSensitive(args, "headers"), *header;
    if (headers && !cJSON_IsObject(headers))
        return false;
    cJSON_ArrayForEach(header,
                       headers) if (!header->string || !cJSON_IsString(header) ||
                                    !xl_home_policy_header(header->string, header->valuestring, r,
                                                           NULL)) return false;
    const cJSON *body = cJSON_GetObjectItemCaseSensitive(args, "body");
    if (body && !cJSON_IsString(body))
        return false;
    const char *value = body ? body->valuestring : "";
    return xl_home_policy_body(value, strlen(value), method, r, NULL);
}
static int left_ms(int64_t deadline) {
    int64_t n = (deadline - esp_timer_get_time()) / 1000;
    return n > 0 ? (int)n : 0;
}
static esp_http_client_method_t method_id(const char *s) {
    if (!strcmp(s, "POST"))
        return HTTP_METHOD_POST;
    if (!strcmp(s, "PUT"))
        return HTTP_METHOD_PUT;
    if (!strcmp(s, "PATCH"))
        return HTTP_METHOD_PATCH;
    if (!strcmp(s, "DELETE"))
        return HTTP_METHOD_DELETE;
    return HTTP_METHOD_GET;
}
cJSON *pdsh_home_run(const xl_home_request_t *r, int64_t deadline) {
    cJSON *out = cJSON_CreateObject();
    if (!out)
        return NULL;
    int64_t timeout_end = esp_timer_get_time() + (int64_t)r->timeout_ms * 1000;
    if (timeout_end < deadline)
        deadline = timeout_end;
    const char *reason = "execution_failed";
    bool applied = false, truncated = false;
    size_t used = 0;
    char body[1025] = {0}, url[340];
    int status = 0;
    esp_transport_handle_t transport = NULL;
    esp_http_client_handle_t client = NULL;
    if (!left_ms(deadline)) {
        reason = "expired";
        goto done;
    }
    snprintf(url, sizeof(url), "http://%s:%u%s", r->host, r->port, r->path);
    transport = xl_home_transport_create(deadline);
    if (!transport)
        goto done;
    esp_http_client_config_t config = {.url = url,
                                       .transport = transport,
                                       .method = method_id(r->method),
                                       .timeout_ms = left_ms(deadline),
                                       .disable_auto_redirect = true,
                                       .keep_alive_enable = false};
    client = esp_http_client_init(&config);
    if (!client)
        goto done;
    for (int i = 0; i < r->header_count; i++)
        if (esp_http_client_set_header(client, r->header_names[i], r->header_values[i]) != ESP_OK)
            goto done;
    if (esp_http_client_set_header(client, "Connection", "close") != ESP_OK ||
        esp_http_client_open(client, r->body_len) != ESP_OK)
        goto done;
    size_t sent = 0;
    while (sent < r->body_len) {
        int n = esp_http_client_write(client, r->body + sent, r->body_len - sent);
        if (n <= 0)
            goto done;
        sent += (size_t)n;
    }
    if (!left_ms(deadline))
        goto done;
    esp_http_client_set_timeout_ms(client, left_ms(deadline));
    if (esp_http_client_fetch_headers(client) < 0)
        goto done;
    status = esp_http_client_get_status_code(client);
    if (status < 100 || status > 599)
        goto done;
    // A 3xx is returned as-is; no second request, even to another private host.
    applied = true;
    while (used < 1024 && status != 204 && status != 304) {
        if (!left_ms(deadline)) {
            truncated = true;
            break;
        }
        esp_http_client_set_timeout_ms(client, left_ms(deadline));
        int n = esp_http_client_read(client, body + used, 1024 - used);
        if (n > 0) {
            used += (size_t)n;
            continue;
        }
        if (!esp_http_client_is_complete_data_received(client))
            truncated = true;
        break;
    }
    if (used == 1024 && !esp_http_client_is_complete_data_received(client))
        truncated = true;
    used = xl_home_utf8_sanitize(body, used, 1024);
done:
    if (client) {
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
    }
    if (transport)
        esp_transport_destroy(transport);
    if (applied) {
        cJSON_AddBoolToObject(out, "applied", true);
        cJSON_AddNumberToObject(out, "http_status", status);
        cJSON_AddStringToObject(out, "body", body);
        cJSON_AddBoolToObject(out, "truncated", truncated);
    } else {
        // The server may have applied a request before a connection/timeout error.
        cJSON_AddBoolToObject(out, "applied", false);
        cJSON_AddStringToObject(out, "outcome", "outcome_unknown");
        cJSON_AddStringToObject(out, "failure_reason", left_ms(deadline) ? reason : "timeout");
    }
    memset(body, 0, sizeof(body));
    return out;
}

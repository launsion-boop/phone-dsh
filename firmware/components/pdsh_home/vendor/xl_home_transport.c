#include "sdkconfig.h"

#if CONFIG_XL_HOME_BRIDGE

/* IDF 5.5.2 exposes esp_http_client_config_t.transport whenever custom
 * transport is enabled. The original tree also required HTTPS support because
 * IDF 5.5.4 moved that assignment inside its HTTPS guard; this project still
 * selects HTTPS in Kconfig so the component keeps building if the SDK is
 * upgraded, but the transport only needs custom transport and zero linger. */
#if !CONFIG_ESP_HTTP_CLIENT_ENABLE_CUSTOM_TRANSPORT || !CONFIG_LWIP_SO_LINGER
#error "xiaozhi-link home bridge requires a custom HTTP transport and zero linger"
#endif

#include "xl_home_transport.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "xl_home_policy.h"
#include "lwip/dns.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "lwip/tcpip.h"

typedef struct {
    char host[XL_HOME_HOST_MAX_BYTES + 1U];
    uint32_t ipv4_be;
    unsigned int references;
    bool completed;
    bool resolved;
    bool abandoned;
} xl_home_dns_query_t;

/* DNS owns one reference until its completion callback, even if the worker's
 * deadline expires first. No callback refers to a task or a stack address. */
static portMUX_TYPE s_dns_lock = portMUX_INITIALIZER_UNLOCKED;
/* Also bound allocations while the lwIP mailbox/timers are stalled. Expired
 * queries retain only these small PSRAM contexts, never a worker or socket. */
#define XL_HOME_DNS_QUERY_LIMIT 4U
static unsigned int s_dns_queries;

static void dns_complete(xl_home_dns_query_t *query, const ip_addr_t *address)
{
    portENTER_CRITICAL(&s_dns_lock);
    query->resolved = address != NULL && IP_IS_V4(address);
    if (query->resolved) {
        query->ipv4_be = ip4_addr_get_u32(ip_2_ip4(address));
    }
    query->completed = true;
    const bool release = --query->references == 0U;
    if (release) {
        --s_dns_queries;
    }
    portEXIT_CRITICAL(&s_dns_lock);
    if (release) {
        heap_caps_free(query);
    }
}

static void dns_found(const char *name, const ip_addr_t *address, void *argument)
{
    (void)name;
    dns_complete((xl_home_dns_query_t *)argument, address);
}

static void dns_start(void *argument)
{
    xl_home_dns_query_t *query = (xl_home_dns_query_t *)argument;
    portENTER_CRITICAL(&s_dns_lock);
    const bool abandoned = query->abandoned;
    portEXIT_CRITICAL(&s_dns_lock);
    if (abandoned) {
        dns_complete(query, NULL);
        return;
    }
    ip_addr_t address;
    const err_t result = dns_gethostbyname_addrtype(
        query->host, &address, dns_found, query, LWIP_DNS_ADDRTYPE_IPV4);
    if (result != ERR_INPROGRESS) {
        dns_complete(query, result == ERR_OK ? &address : NULL);
    }
}

esp_err_t xl_home_resolve_private_ipv4(const char *host,
                                         int64_t deadline_us,
                                         uint32_t *out_be)
{
    if (host == NULL || out_be == NULL || host[0] == '\0' ||
        strlen(host) > XL_HOME_HOST_MAX_BYTES) {
        return ESP_ERR_INVALID_ARG;
    }
    if (esp_timer_get_time() >= deadline_us) {
        return ESP_ERR_TIMEOUT;
    }
    portENTER_CRITICAL(&s_dns_lock);
    const bool available = s_dns_queries < XL_HOME_DNS_QUERY_LIMIT;
    if (available) {
        ++s_dns_queries;
    }
    portEXIT_CRITICAL(&s_dns_lock);
    if (!available) {
        return ESP_ERR_NO_MEM;
    }
    xl_home_dns_query_t *query = heap_caps_calloc(
        1U, sizeof(*query), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (query == NULL) {
        portENTER_CRITICAL(&s_dns_lock);
        --s_dns_queries;
        portEXIT_CRITICAL(&s_dns_lock);
        return ESP_ERR_NO_MEM;
    }
    memcpy(query->host, host, strlen(host) + 1U);
    query->references = 2U;
    /* Unlike tcpip_callback(), this cannot wait indefinitely for a full
     * mailbox. DNS is always invoked in its required lwIP thread context. */
    if (tcpip_try_callback(dns_start, query) != ERR_OK) {
        heap_caps_free(query);
        portENTER_CRITICAL(&s_dns_lock);
        --s_dns_queries;
        portEXIT_CRITICAL(&s_dns_lock);
        return ESP_FAIL;
    }

    esp_err_t result = ESP_ERR_TIMEOUT;
    while (esp_timer_get_time() < deadline_us) {
        portENTER_CRITICAL(&s_dns_lock);
        const bool completed = query->completed;
        const bool resolved = query->resolved;
        const uint32_t ipv4_be = query->ipv4_be;
        portEXIT_CRITICAL(&s_dns_lock);
        if (completed) {
            if (resolved && xl_home_ipv4_private(ipv4_be)) {
                *out_be = ipv4_be;
                result = ESP_OK;
            } else {
                result = ESP_FAIL;
            }
            break;
        }
        /* One tick bounds scheduling overshoot; there is no extra DNS task,
         * semaphore or task notification that could outlive the worker. */
        vTaskDelay(1);
    }
    portENTER_CRITICAL(&s_dns_lock);
    query->abandoned = true;
    const bool release = --query->references == 0U;
    if (release) {
        --s_dns_queries;
    }
    portEXIT_CRITICAL(&s_dns_lock);
    if (release) {
        heap_caps_free(query);
    }
    return result;
}

typedef struct {
    int64_t deadline_us;
    int socket_fd;
} xl_home_tcp_t;

static int64_t io_deadline(const xl_home_tcp_t *tcp, int timeout_ms)
{
    int64_t deadline = tcp->deadline_us;
    if (timeout_ms >= 0) {
        const int64_t relative = esp_timer_get_time() +
                                 (int64_t)timeout_ms * 1000LL;
        if (relative < deadline) {
            deadline = relative;
        }
    }
    return deadline;
}

static int wait_socket(xl_home_tcp_t *tcp, bool writing, int64_t deadline_us)
{
    if (tcp->socket_fd < 0 || tcp->socket_fd >= FD_SETSIZE) {
        errno = EBADF;
        return -1;
    }
    for (;;) {
        const int64_t left_us = deadline_us - esp_timer_get_time();
        if (left_us <= 0) {
            errno = ETIMEDOUT;
            return 0;
        }
        fd_set ready;
        fd_set errors;
        FD_ZERO(&ready);
        FD_ZERO(&errors);
        FD_SET(tcp->socket_fd, &ready);
        FD_SET(tcp->socket_fd, &errors);
        struct timeval timeout = {
            .tv_sec = (long)(left_us / 1000000LL),
            .tv_usec = (long)(left_us % 1000000LL),
        };
        const int result = select(tcp->socket_fd + 1,
                                  writing ? NULL : &ready,
                                  writing ? &ready : NULL, &errors, &timeout);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (esp_timer_get_time() >= deadline_us || result == 0) {
            errno = ETIMEDOUT;
            return 0;
        }
        if (result < 0) {
            return -1;
        }
        /* Like IDF's TCP transport, drain readable bytes before reporting a
         * simultaneous error (for example, a response immediately followed
         * by RST). Writes/connects must still reject socket errors first. */
        if (FD_ISSET(tcp->socket_fd, &errors) &&
            (writing || !FD_ISSET(tcp->socket_fd, &ready))) {
            int error = 0;
            socklen_t length = sizeof(error);
            if (getsockopt(tcp->socket_fd, SOL_SOCKET, SO_ERROR,
                           &error, &length) == 0) {
                errno = error != 0 ? error : EIO;
            }
            return -1;
        }
        return 1;
    }
}

static int tcp_close(esp_transport_handle_t transport)
{
    xl_home_tcp_t *tcp = esp_transport_get_context_data(transport);
    if (tcp->socket_fd < 0) {
        return 0;
    }
    const int socket_fd = tcp->socket_fd;
    tcp->socket_fd = -1;
    return close(socket_fd);
}

static int tcp_connect(esp_transport_handle_t transport, const char *host,
                       int port, int timeout_ms)
{
    xl_home_tcp_t *tcp = esp_transport_get_context_data(transport);
    const int64_t deadline_us = io_deadline(tcp, timeout_ms);
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)port),
    };
    /* Resolution already happened once under the same deadline. Never do a
     * second DNS lookup here: it could both block and permit DNS rebinding. */
    if (port <= 0 || port > UINT16_MAX ||
        inet_pton(AF_INET, host, &address.sin_addr) != 1 ||
        !xl_home_ipv4_private(address.sin_addr.s_addr)) {
        errno = EINVAL;
        return -1;
    }
    if (esp_timer_get_time() >= deadline_us) {
        errno = ETIMEDOUT;
        return -1;
    }
    (void)tcp_close(transport);
    tcp->socket_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (tcp->socket_fd < 0) {
        return -1;
    }
    const int flags = fcntl(tcp->socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(tcp->socket_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        goto failed;
    }
    /* Nonblocking alone does not bound lwIP close() if FIN allocation fails.
     * No connection is reused; zero linger also prevents that cleanup wait. */
    const struct linger linger = {.l_onoff = 1, .l_linger = 0};
    if (setsockopt(tcp->socket_fd, SOL_SOCKET, SO_LINGER,
                   &linger, sizeof(linger)) != 0) {
        goto failed;
    }
    const int connected = connect(tcp->socket_fd,
                                   (struct sockaddr *)&address,
                                   sizeof(address));
    if (connected < 0) {
        if (errno != EINPROGRESS && errno != EWOULDBLOCK &&
            errno != EALREADY) {
            goto failed;
        }
        if (wait_socket(tcp, true, deadline_us) != 1) {
            goto failed;
        }
        int error = 0;
        socklen_t length = sizeof(error);
        if (getsockopt(tcp->socket_fd, SOL_SOCKET, SO_ERROR,
                       &error, &length) != 0) {
            goto failed;
        }
        if (error != 0) {
            errno = error;
            goto failed;
        }
    }
    if (esp_timer_get_time() >= deadline_us) {
        errno = ETIMEDOUT;
        goto failed;
    }
    return 0;

failed:;
    const int error = errno;
    (void)tcp_close(transport);
    errno = error;
    return -1;
}

static int tcp_read(esp_transport_handle_t transport, char *buffer, int length,
                    int timeout_ms)
{
    xl_home_tcp_t *tcp = esp_transport_get_context_data(transport);
    const int64_t deadline_us = io_deadline(tcp, timeout_ms);
    for (;;) {
        const int ready = wait_socket(tcp, false, deadline_us);
        if (ready <= 0) {
            return ready == 0 ? ERR_TCP_TRANSPORT_CONNECTION_TIMEOUT
                              : ERR_TCP_TRANSPORT_CONNECTION_FAILED;
        }
        const int count = recv(tcp->socket_fd, buffer, (size_t)length, 0);
        if (count > 0) {
            return count;
        }
        if (count == 0) {
            /* esp_http_client distinguishes FIN from timeout, notably for
             * valid HTTP responses framed by connection close. */
            return ERR_TCP_TRANSPORT_CONNECTION_CLOSED_BY_FIN;
        }
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            return ERR_TCP_TRANSPORT_CONNECTION_FAILED;
        }
    }
}

static int tcp_write(esp_transport_handle_t transport, const char *buffer,
                     int length, int timeout_ms)
{
    xl_home_tcp_t *tcp = esp_transport_get_context_data(transport);
    const int64_t deadline_us = io_deadline(tcp, timeout_ms);
    for (;;) {
        const int ready = wait_socket(tcp, true, deadline_us);
        if (ready <= 0) {
            return ready;
        }
        const int count = send(tcp->socket_fd, buffer, (size_t)length, 0);
        if (count >= 0) {
            return count;
        }
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            return -1;
        }
    }
}

static int tcp_poll_read(esp_transport_handle_t transport, int timeout_ms)
{
    xl_home_tcp_t *tcp = esp_transport_get_context_data(transport);
    return wait_socket(tcp, false, io_deadline(tcp, timeout_ms));
}

static int tcp_poll_write(esp_transport_handle_t transport, int timeout_ms)
{
    xl_home_tcp_t *tcp = esp_transport_get_context_data(transport);
    return wait_socket(tcp, true, io_deadline(tcp, timeout_ms));
}

static int tcp_destroy(esp_transport_handle_t transport)
{
    (void)tcp_close(transport);
    heap_caps_free(esp_transport_get_context_data(transport));
    return 0;
}

esp_transport_handle_t xl_home_transport_create(int64_t deadline_us)
{
    xl_home_tcp_t *tcp = heap_caps_calloc(
        1U, sizeof(*tcp), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (tcp == NULL) {
        return NULL;
    }
    esp_transport_handle_t transport = esp_transport_init();
    if (transport == NULL) {
        heap_caps_free(tcp);
        return NULL;
    }
    tcp->deadline_us = deadline_us;
    tcp->socket_fd = -1;
    (void)esp_transport_set_context_data(transport, tcp);
    (void)esp_transport_set_func(transport, tcp_connect, tcp_read, tcp_write,
                                  tcp_close, tcp_poll_read, tcp_poll_write,
                                  tcp_destroy);
    return transport;
}

#endif

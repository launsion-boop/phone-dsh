#include "stubs/adapter.h"

#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Include the production source to exercise callbacks through their actual
 * registered transport, and to assert the abandoned-DNS allocation bound. */
#include "../../components/pdsh_home/pdsh_home_transport.c"

static int64_t now_us;
static unsigned int allocations;
static unsigned int frees;
static bool mailbox_reject;
static bool mailbox_stalled;
static tcpip_callback_fn mailbox_callback[8];
static void *mailbox_argument[8];
static unsigned int mailbox_count;
static dns_found_callback dns_callback[8];
static void *dns_argument[8];
static unsigned int dns_count;
static enum { DNS_CACHED, DNS_FAIL, DNS_PENDING } dns_mode;
static uint32_t dns_address;
static bool fail_allocate;
static bool fail_transport_allocate;
static int64_t select_step_us;
static unsigned int interrupted_selects;
static bool select_not_ready;
static bool select_error_ready;
static bool select_error_only;
static int connect_error;
static int socket_error;
static bool recv_again;
static bool recv_closed;
static bool send_again;
static unsigned int socket_closes;
static bool socket_nonblocking;
static bool socket_zero_linger;

int64_t esp_timer_get_time(void) { return now_us; }

void *heap_caps_calloc(size_t count, size_t size, unsigned int caps)
{
    assert(caps == (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    if (fail_allocate) return NULL;
    void *value = calloc(count, size);
    assert(value != NULL);
    ++allocations;
    return value;
}

void heap_caps_free(void *value)
{
    assert(value != NULL);
    ++frees;
    free(value);
}

err_t tcpip_try_callback(tcpip_callback_fn callback, void *argument)
{
    if (mailbox_reject) return ERR_MEM;
    assert(mailbox_count < 8U);
    mailbox_callback[mailbox_count] = callback;
    mailbox_argument[mailbox_count++] = argument;
    return ERR_OK;
}

static void drain_mailbox(void)
{
    while (mailbox_count > 0U) {
        const unsigned int index = --mailbox_count;
        mailbox_callback[index](mailbox_argument[index]);
    }
}

void vTaskDelay(unsigned int ticks)
{
    now_us += (int64_t)ticks * 1000LL;
    if (!mailbox_stalled) drain_mailbox();
}

err_t dns_gethostbyname_addrtype(const char *host, ip_addr_t *address,
                                dns_found_callback callback, void *argument,
                                unsigned char address_type)
{
    assert(strcmp(host, "host.local") == 0);
    assert(address_type == LWIP_DNS_ADDRTYPE_IPV4);
    if (dns_mode == DNS_CACHED) {
        address->addr = dns_address;
        return ERR_OK;
    }
    if (dns_mode == DNS_FAIL) return ERR_ARG;
    assert(dns_count < 8U);
    dns_callback[dns_count] = callback;
    dns_argument[dns_count++] = argument;
    return ERR_INPROGRESS;
}

static void complete_dns(bool success)
{
    assert(dns_count > 0U);
    const unsigned int index = --dns_count;
    const ip_addr_t address = {.addr = dns_address};
    dns_callback[index]("host.local", success ? &address : NULL,
                       dns_argument[index]);
}

esp_transport_handle_t esp_transport_init(void)
{
    return fail_transport_allocate ? NULL : calloc(1U, sizeof(struct test_transport));
}

void *esp_transport_get_context_data(esp_transport_handle_t transport)
{
    return transport->context;
}

esp_err_t esp_transport_set_context_data(esp_transport_handle_t transport,
                                        void *context)
{
    transport->context = context;
    return ESP_OK;
}

esp_err_t esp_transport_set_func(esp_transport_handle_t transport,
    connect_func on_connect, io_read_func on_read, io_func on_write,
    trans_func on_close, poll_func on_poll_read, poll_func on_poll_write,
    trans_func on_destroy)
{
    transport->cb_connect = on_connect;
    transport->cb_read = on_read;
    transport->cb_write = on_write;
    transport->cb_close = on_close;
    transport->cb_poll_read = on_poll_read;
    transport->cb_poll_write = on_poll_write;
    transport->cb_destroy = on_destroy;
    return ESP_OK;
}

int test_socket(int domain, int type, int protocol)
{
    assert(domain == AF_INET && type == SOCK_STREAM && protocol == IPPROTO_TCP);
    return 10;
}

int test_fcntl(int fd, int command, ...)
{
    assert(fd == 10);
    if (command == F_GETFL) return 0;
    assert(command == F_SETFL);
    va_list arguments;
    va_start(arguments, command);
    socket_nonblocking = (va_arg(arguments, int) & O_NONBLOCK) != 0;
    va_end(arguments);
    return 0;
}

int test_setsockopt(int fd, int level, int option, const void *value,
                    socklen_t length)
{
    assert(fd == 10 && level == SOL_SOCKET && option == SO_LINGER);
    assert(length == sizeof(struct linger));
    const struct linger *linger = value;
    socket_zero_linger = linger->l_onoff == 1 && linger->l_linger == 0;
    return 0;
}

int test_getsockopt(int fd, int level, int option, void *value, socklen_t *length)
{
    assert(fd == 10 && level == SOL_SOCKET && option == SO_ERROR);
    assert(*length == sizeof(int));
    *(int *)value = socket_error;
    return 0;
}

int test_connect(int fd, const struct sockaddr *address, socklen_t length)
{
    assert(fd == 10 && length == sizeof(struct sockaddr_in));
    assert(address->sa_family == AF_INET);
    assert(socket_nonblocking && socket_zero_linger);
    errno = connect_error;
    return connect_error == 0 ? 0 : -1;
}

int test_select(int nfds, fd_set *read_set, fd_set *write_set, fd_set *errors,
                 struct timeval *timeout)
{
    assert(nfds == 11 && (read_set != NULL || write_set != NULL));
    const int64_t budget = (int64_t)timeout->tv_sec * 1000000LL + timeout->tv_usec;
    assert(budget > 0);
    if (select_not_ready || select_step_us >= budget) {
        now_us += budget;
        return 0;
    }
    now_us += select_step_us;
    if (interrupted_selects > 0U) {
        --interrupted_selects;
        errno = EINTR;
        return -1;
    }
    FD_ZERO(errors);
    if (select_error_ready) {
        FD_SET(10, errors);
        if (select_error_only) {
            if (read_set != NULL) FD_ZERO(read_set);
            if (write_set != NULL) FD_ZERO(write_set);
        }
    }
    return 1;
}

ssize_t test_recv(int fd, void *buffer, size_t length, int flags)
{
    assert(fd == 10 && length > 0U && flags == 0 && socket_nonblocking);
    if (recv_again) {
        errno = EAGAIN;
        return -1;
    }
    if (recv_closed) return 0;
    *(char *)buffer = 'x';
    return 1;
}

ssize_t test_send(int fd, const void *buffer, size_t length, int flags)
{
    assert(fd == 10 && buffer != NULL && length > 0U && flags == 0);
    assert(socket_nonblocking);
    if (send_again) {
        errno = EAGAIN;
        return -1;
    }
    return length > 2U ? 2 : (ssize_t)length;
}

int test_close(int fd)
{
    assert(fd == 10);
    ++socket_closes;
    return 0;
}

static void reset(void)
{
    assert(allocations == frees && s_dns_queries == 0U);
    assert(mailbox_count == 0U && dns_count == 0U);
    now_us = 0;
    mailbox_reject = mailbox_stalled = false;
    dns_mode = DNS_CACHED;
    dns_address = inet_addr("192.168.1.10");
    fail_allocate = fail_transport_allocate = false;
    select_step_us = 200000;
    interrupted_selects = 0U;
    select_not_ready = false;
    select_error_ready = select_error_only = false;
    connect_error = socket_error = 0;
    recv_again = recv_closed = send_again = false;
    socket_closes = 0U;
    socket_nonblocking = socket_zero_linger = false;
}

static void destroy_transport(esp_transport_handle_t transport)
{
    transport->cb_destroy(transport);
    free(transport);
}

static esp_transport_handle_t connected_transport(int64_t deadline)
{
    esp_transport_handle_t transport = xl_home_transport_create(deadline);
    assert(transport != NULL);
    assert(transport->cb_connect(transport, "192.168.1.10", 80, 10000) == 0);
    return transport;
}

static void test_dns_lifetimes(void)
{
    uint32_t address = 0;
    reset();
    assert(xl_home_resolve_private_ipv4("host.local", 10000, &address) == ESP_OK);
    assert(address == dns_address);
    reset();
    dns_address = inet_addr("8.8.8.8");
    assert(xl_home_resolve_private_ipv4("host.local", 10000, &address) == ESP_FAIL);
    reset();
    dns_mode = DNS_FAIL;
    assert(xl_home_resolve_private_ipv4("host.local", 10000, &address) == ESP_FAIL);
    reset();
    mailbox_reject = true;
    assert(xl_home_resolve_private_ipv4("host.local", 10000, &address) == ESP_FAIL);
    assert(allocations == frees);
    reset();
    fail_allocate = true;
    assert(xl_home_resolve_private_ipv4("host.local", 10000, &address) == ESP_ERR_NO_MEM);
    reset();
    for (unsigned int success = 0; success < 2U; ++success) {
        dns_mode = DNS_PENDING;
        assert(xl_home_resolve_private_ipv4("host.local", now_us + 10000,
                                               &address) == ESP_ERR_TIMEOUT);
        assert(allocations == frees + 1U && s_dns_queries == 1U);
        complete_dns(success != 0U);
        assert(allocations == frees && s_dns_queries == 0U);
    }
    reset();
    dns_mode = DNS_PENDING;
    for (unsigned int index = 0; index < XL_HOME_DNS_QUERY_LIMIT; ++index) {
        assert(xl_home_resolve_private_ipv4("host.local", now_us + 10000,
                                               &address) == ESP_ERR_TIMEOUT);
    }
    assert(xl_home_resolve_private_ipv4("host.local", now_us + 10000,
                                           &address) == ESP_ERR_NO_MEM);
    assert(allocations == frees + XL_HOME_DNS_QUERY_LIMIT);
    while (dns_count > 0U) complete_dns(false);
    reset();
    mailbox_stalled = true;
    assert(xl_home_resolve_private_ipv4("host.local", 10000, &address) == ESP_ERR_TIMEOUT);
    assert(dns_count == 0U && allocations == frees + 1U);
    drain_mailbox();
    assert(dns_count == 0U && allocations == frees);
    reset();
}

static void test_socket_deadlines(void)
{
    char buffer[32];
    reset();
    esp_transport_handle_t transport = connected_transport(1000000);
    unsigned int received = 0;
    int result;
    /* A peer that is continually readable must not renew the total budget. */
    while ((result = transport->cb_read(transport, buffer, sizeof(buffer), 10000)) > 0) {
        received += (unsigned int)result;
        assert(received < 10U);
    }
    assert(result == ERR_TCP_TRANSPORT_CONNECTION_TIMEOUT);
    assert(received == 4U && now_us == 1000000);
    destroy_transport(transport);
    assert(socket_closes == 1U);
    reset();
    transport = connected_transport(1000000);
    unsigned int written = 0;
    while ((result = transport->cb_write(transport, "partial write", 13, 10000)) > 0) {
        written += (unsigned int)result;
        assert(written < 20U);
    }
    assert(result == 0 && written == 8U && now_us == 1000000);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    recv_again = true;
    assert(transport->cb_read(transport, buffer, sizeof(buffer), 10000) == 0);
    assert(now_us == 1000000);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    send_again = true;
    assert(transport->cb_write(transport, "body", 4, 10000) == 0);
    assert(now_us == 1000000);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    select_error_ready = true;
    socket_error = ECONNRESET;
    /* A server may send its last response bytes then reset the connection.
     * Both fd sets are ready; preserve those bytes before surfacing RST. */
    assert(transport->cb_read(transport, buffer, sizeof(buffer), 10000) == 1);
    assert(buffer[0] == 'x');
    select_error_only = true;
    assert(transport->cb_read(transport, buffer, sizeof(buffer), 10000) ==
           ERR_TCP_TRANSPORT_CONNECTION_FAILED);
    assert(errno == ECONNRESET);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    select_error_ready = true;
    socket_error = ECONNRESET;
    assert(transport->cb_write(transport, "body", 4, 10000) == -1);
    assert(errno == ECONNRESET);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    interrupted_selects = 20U;
    assert(transport->cb_read(transport, buffer, sizeof(buffer), 10000) == 0);
    assert(now_us == 1000000);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    recv_closed = true;
    assert(transport->cb_read(transport, buffer, sizeof(buffer), 10000) ==
           ERR_TCP_TRANSPORT_CONNECTION_CLOSED_BY_FIN);
    destroy_transport(transport);
    reset();
    transport = xl_home_transport_create(1000000);
    connect_error = EINPROGRESS;
    select_not_ready = true;
    assert(transport->cb_connect(transport, "192.168.1.10", 80, 10000) == -1);
    assert(now_us == 1000000 && errno == ETIMEDOUT && socket_closes == 1U);
    destroy_transport(transport);
    assert(socket_closes == 1U);
    reset();
    transport = xl_home_transport_create(1000000);
    connect_error = EINPROGRESS;
    socket_error = ECONNREFUSED;
    assert(transport->cb_connect(transport, "192.168.1.10", 80, 10000) == -1);
    assert(errno == ECONNREFUSED && socket_closes == 1U);
    destroy_transport(transport);
    reset();
    transport = connected_transport(1000000);
    assert(transport->cb_write(transport, "body", 4, 10000) == 2);
    select_not_ready = true;
    assert(transport->cb_read(transport, buffer, sizeof(buffer), 10000) == 0);
    assert(now_us == 1000000); /* write and read consume the SAME budget */
    destroy_transport(transport);
    reset();
    fail_transport_allocate = true;
    assert(xl_home_transport_create(1000000) == NULL);
    reset();
}

int main(void)
{
    test_dns_lifetimes();
    test_socket_deadlines();
    puts("xl_home_transport_host_test: deadline, DNS lifetime and allocation bound ok");
    return 0;
}

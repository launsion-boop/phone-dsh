#pragma once

/* Deterministic host stand-ins for scheduler, lwIP and esp_transport. The
 * regression test compiles the real xl_home_transport.c against these. */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#define CONFIG_XL_HOME_BRIDGE 1
#define CONFIG_ESP_HTTP_CLIENT_ENABLE_CUSTOM_TRANSPORT 1
#define CONFIG_ESP_HTTP_CLIENT_ENABLE_HTTPS 1
#define CONFIG_LWIP_SO_LINGER 1
typedef int esp_err_t;
#define ESP_OK 0
#define ESP_FAIL -1
#define ESP_ERR_NO_MEM 0x101
#define ESP_ERR_INVALID_ARG 0x102
#define ESP_ERR_TIMEOUT 0x107
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_8BIT 2

typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) ((void)(lock))
#define portEXIT_CRITICAL(lock) ((void)(lock))
void vTaskDelay(unsigned int ticks);
int64_t esp_timer_get_time(void);
void *heap_caps_calloc(size_t count, size_t size, unsigned int caps);
void heap_caps_free(void *value);

typedef int err_t;
#define ERR_OK 0
#define ERR_MEM -1
#define ERR_INPROGRESS -5
#define ERR_ARG -16
#define LWIP_DNS_ADDRTYPE_IPV4 0
typedef struct { uint32_t addr; } ip_addr_t;
#define IP_IS_V4(address) ((address) != NULL)
#define ip_2_ip4(address) (address)
#define ip4_addr_get_u32(address) ((address)->addr)
typedef void (*dns_found_callback)(const char *, const ip_addr_t *, void *);
typedef void (*tcpip_callback_fn)(void *);
err_t tcpip_try_callback(tcpip_callback_fn callback, void *argument);
err_t dns_gethostbyname_addrtype(const char *host, ip_addr_t *address,
                                dns_found_callback callback, void *argument,
                                unsigned char address_type);

typedef struct test_transport *esp_transport_handle_t;
typedef int (*connect_func)(esp_transport_handle_t, const char *, int, int);
typedef int (*io_read_func)(esp_transport_handle_t, char *, int, int);
typedef int (*io_func)(esp_transport_handle_t, const char *, int, int);
typedef int (*trans_func)(esp_transport_handle_t);
typedef int (*poll_func)(esp_transport_handle_t, int);
struct test_transport {
    void *context;
    connect_func cb_connect;
    io_read_func cb_read;
    io_func cb_write;
    trans_func cb_close;
    poll_func cb_poll_read;
    poll_func cb_poll_write;
    trans_func cb_destroy;
};
enum {
    ERR_TCP_TRANSPORT_CONNECTION_FAILED = -2,
    ERR_TCP_TRANSPORT_CONNECTION_CLOSED_BY_FIN = -1,
    ERR_TCP_TRANSPORT_CONNECTION_TIMEOUT = 0,
};
esp_transport_handle_t esp_transport_init(void);
void *esp_transport_get_context_data(esp_transport_handle_t transport);
esp_err_t esp_transport_set_context_data(esp_transport_handle_t transport,
                                        void *context);
esp_err_t esp_transport_set_func(esp_transport_handle_t transport,
    connect_func connect, io_read_func read, io_func write, trans_func close,
    poll_func poll_read, poll_func poll_write, trans_func destroy);

int test_socket(int domain, int type, int protocol);
int test_fcntl(int fd, int command, ...);
int test_setsockopt(int fd, int level, int option, const void *value,
                    socklen_t length);
int test_getsockopt(int fd, int level, int option, void *value,
                    socklen_t *length);
int test_connect(int fd, const struct sockaddr *address, socklen_t length);
int test_select(int nfds, fd_set *read, fd_set *write, fd_set *errors,
                 struct timeval *timeout);
ssize_t test_recv(int fd, void *buffer, size_t length, int flags);
ssize_t test_send(int fd, const void *buffer, size_t length, int flags);
int test_close(int fd);

#define socket test_socket
#define fcntl test_fcntl
#define setsockopt test_setsockopt
#define getsockopt test_getsockopt
#define connect test_connect
#define select test_select
#define recv test_recv
#define send test_send
#define close test_close

#ifndef MALLOC_CAP_INTERNAL
#define MALLOC_CAP_INTERNAL 0x04
#endif

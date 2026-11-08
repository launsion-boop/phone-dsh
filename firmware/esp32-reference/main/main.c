// SPDX-License-Identifier: MIT
#include "driver/gpio.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/ble_store.h"
#include "host/util/util.h"
#include "link_tools.h"
#include "pdsh_enroll.h"
#include "pdsh_identity.h"
#include "pdsh_secure_cert.h"
#include "pdsh_secure_session.h"
#include "pdsh_task_store.h"
#include "psa/crypto.h"
/* §5 credit mechanism: the CoC receive function of the pinned NimBLE
 * (ESP-IDF v6.1 fff9895c, ble_l2cap_coc_rx_fn) dereferences the receive slot
 * before checking credits. This firmware never lets it run: on
 * BLE_L2CAP_EVENT_COC_ACCEPT (before the connection response, so before any
 * K-frame can arrive) chan->rx_fn is replaced by secure_coc_rx, which checks
 * credits first (pdsh_ss_coc_kframe) and returns credits only after TLS
 * consumed an SDU. The private NimBLE headers are pinned to that revision. */
#include "ble_l2cap_priv.h"
#include "ble_l2cap_sig_priv.h"
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
#include "driver/usb_serial_jtag.h"
#elif CONFIG_ESP_CONSOLE_UART
#include "driver/uart.h"
#endif
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "pdsh_link_wire.h"
#include "sdkconfig.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define UUID(n)                                                                                    \
    BLE_UUID128_INIT(0x00, 0x6b, 0x6e, 0x69, 0x6c, 0x78, 0x1e, 0x9a, 0x5a, 0x4c, 0x1b, 0x7f,       \
                     (n) & 255, ((n) >> 8) & 255, 0x40, 0x6e)
static const ble_uuid128_t service_uuid = UUID(0x0100), rx_uuid = UUID(0x0101),
                           tx_uuid = UUID(0x0102), audio_uuid = UUID(0x0103);
static uint16_t tx_handle, audio_handle;
/* §5 secure session service d04ea024-c7fd-4a52-9ace-cf9d7567d0e6 with the
 * Apple L2CAP PSM characteristic abdd3056-28fa-441d-a470-55a75a52553a. */
static const ble_uuid128_t secure_uuid = BLE_UUID128_INIT(0xe6, 0xd0, 0x67, 0x75, 0x9d, 0xcf, 0xce, 0x9a, 0x52,
                                                          0x4a, 0xfd, 0xc7, 0x24, 0xa0, 0x4e, 0xd0);
static const ble_uuid128_t psm_uuid = BLE_UUID128_INIT(0x3a, 0x55, 0x52, 0x5a, 0xa7, 0x55, 0x70, 0xa4, 0x1d, 0x44,
                                                       0xfa, 0x28, 0x56, 0x30, 0xdd, 0xab);
#define SECURE_PSM 0x00A5
#define SECURE_MTU 512
static bool secure_available;
static uint8_t address_type;
static uint32_t boot_id, app_caps, event_seq;
static atomic_uint connection = BLE_HS_CONN_HANDLE_NONE, generation = 1;
static atomic_bool ready = false, tx_subscribed = false, audio_subscribed = false;
static pdsh_reassembly_t reassembly;
static atomic_int_fast64_t pairing_until;
typedef struct {
    uint32_t generation;
    uint16_t len;
    uint8_t data[512];
} message_t;
static QueueHandle_t messages;
void ble_store_config_init(void);
static uint16_t u16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }
static uint32_t u32(const uint8_t *p) { return u16(p) | (uint32_t)u16(p + 2) << 16; }
static void put16(uint8_t *p, uint16_t v) {
    p[0] = v;
    p[1] = v >> 8;
}
static void put32(uint8_t *p, uint32_t v) {
    put16(p, v);
    put16(p + 2, v >> 16);
}
static bool secure(void) {
    struct ble_gap_conn_desc desc;
    return ble_gap_conn_find(atomic_load(&connection), &desc) == 0 && desc.sec_state.encrypted &&
           desc.sec_state.bonded;
}
static void advertise(void);
static int gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status) {
            advertise();
            break;
        }
        atomic_store(&connection, event->connect.conn_handle);
        atomic_fetch_add(&generation, 1);
        atomic_store(&ready, false);
        atomic_store(&tx_subscribed, false);
        atomic_store(&audio_subscribed, false);
        memset(&reassembly, 0, sizeof(reassembly));
        struct ble_gap_conn_desc desc;
        struct ble_store_key_sec key = {0};
        struct ble_store_value_sec value;
        ble_gap_conn_find(event->connect.conn_handle, &desc);
        key.peer_addr = desc.peer_id_addr;
        // Existing bonds may reconnect at any time. New bonds require the physical window.
        int bonds = 0;
        ble_store_util_count(BLE_STORE_OBJ_TYPE_PEER_SEC, &bonds);
        if (ble_store_read_peer_sec(&key, &value) != 0 &&
            (bonds > 0 || esp_timer_get_time() > atomic_load(&pairing_until))) {
            ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            break;
        }
        if (ble_gap_security_initiate(event->connect.conn_handle) != 0)
            ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        atomic_store(&ready, false);
        atomic_store(&connection, BLE_HS_CONN_HANDLE_NONE);
        atomic_fetch_add(&generation, 1);
        memset(&reassembly, 0, sizeof(reassembly));
        advertise();
        break;
    case BLE_GAP_EVENT_ENC_CHANGE:
        if (event->enc_change.status || !secure())
            ble_gap_terminate(event->enc_change.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == tx_handle)
            atomic_store(&tx_subscribed, event->subscribe.cur_notify);
        if (event->subscribe.attr_handle == audio_handle)
            atomic_store(&audio_subscribed, event->subscribe.cur_notify);
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    default:
        break;
    }
    return 0;
}
static void advertise(void) {
    struct ble_hs_adv_fields fields = {0}, scan = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    const char *name = "PDSH ESP32 Link";
    scan.name = (uint8_t *)name;
    scan.name_len = strlen(name);
    scan.name_is_complete = 1;
    ble_gap_adv_set_fields(&fields);
    ble_gap_adv_rsp_set_fields(&scan);
    struct ble_gap_adv_params params = {.conn_mode = BLE_GAP_CONN_MODE_UND,
                                        .disc_mode = BLE_GAP_DISC_MODE_GEN};
    ble_gap_adv_start(address_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
}
static void sync_host(void) {
    if (ble_hs_id_infer_auto(0, &address_type) == 0)
        advertise();
}
static int access_gatt(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)attr;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    if (conn != atomic_load(&connection) || !secure())
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    uint8_t bytes[244];
    uint16_t n = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, bytes, sizeof(bytes), &n) != 0)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    int result = pdsh_segment(&reassembly, bytes, n);
    if (result < 0)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (result == 1) {
        message_t message = {.generation = atomic_load(&generation), .len = reassembly.len};
        memcpy(message.data, reassembly.data, message.len);
        if (xQueueSend(messages, &message, 0) != pdTRUE) {
            atomic_store(&ready, false);
            ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
    }
    return 0;
}
static int access_psm(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn;
    (void)attr;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return BLE_ATT_ERR_READ_NOT_PERMITTED;
    uint8_t value[2] = {SECURE_PSM & 0xff, SECURE_PSM >> 8};
    return os_mbuf_append(ctxt->om, value, sizeof(value)) ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
}
static const struct ble_gatt_svc_def secure_services[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY,
     .uuid = &secure_uuid.u,
     .characteristics = (struct ble_gatt_chr_def[]){
         {.uuid = &psm_uuid.u, .access_cb = access_psm, .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC},
         {0}}},
    {0}};
static const struct ble_gatt_svc_def services[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY,
     .uuid = &service_uuid.u,
     .characteristics =
         (struct ble_gatt_chr_def[]){{.uuid = &rx_uuid.u,
                                      .access_cb = access_gatt,
                                      .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP |
                                               BLE_GATT_CHR_F_WRITE_ENC},
                                     {.uuid = &tx_uuid.u,
                                      .access_cb = access_gatt,
                                      .flags = BLE_GATT_CHR_F_NOTIFY,
                                      .val_handle = &tx_handle},
                                     {.uuid = &audio_uuid.u,
                                      .access_cb = access_gatt,
                                      .flags = BLE_GATT_CHR_F_NOTIFY,
                                      .val_handle = &audio_handle},
                                     {0}}},
    {0}};
static bool notify_frame(uint8_t op, uint16_t id, const uint8_t *body, size_t n, uint32_t gen) {
    uint8_t frame[512];
    size_t len = pdsh_frame(op, id, body, n, frame);
    uint16_t conn = atomic_load(&connection);
    int budget = ble_att_mtu(conn) - 3;
    if (budget > 244)
        budget = 244;
    if (budget < 20)
        budget = 20;
    for (size_t off = 0; off < len;) {
        size_t take = len - off;
        if (take > (size_t)budget - 1)
            take = budget - 1;
        uint8_t packet[244];
        packet[0] = (off == 0 ? 2 : 0) | (off + take == len ? 1 : 0);
        memcpy(packet + 1, frame + off, take);
        int err = -1;
        for (int retry = 0; retry < 30; retry++) {
            if (gen != atomic_load(&generation) || !secure() || !atomic_load(&tx_subscribed) ||
                !atomic_load(&ready))
                return false;
            struct os_mbuf *om = ble_hs_mbuf_from_flat(packet, take + 1);
            if (om)
                err = ble_gatts_notify_custom(conn, tx_handle, om);
            if (err == 0)
                break;
            vTaskDelay(pdMS_TO_TICKS(10));
        }
        if (err) {
            ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
            return false;
        }
        off += take;
    }
    return true;
}
static void status_info(uint8_t out[35]) {
    memset(out, 0, 35);
    put32(out + 4, esp_timer_get_time() / 1000000);
    put16(out + 33, ble_att_mtu(atomic_load(&connection)));
}

/* ===================== secure session binding (§5) ===================== */

static SemaphoreHandle_t secure_lock;
static struct {
    struct ble_l2cap_chan *chan; /* the one CoC (global limit 1) */
    uint16_t conn_handle, peer_mtu;
    bool accepted, opened, reached_open, closing;
    pdsh_ss_coc_t coc;
    pdsh_ss_tx_t tx;
    pdsh_ss_conn_t *tls;
    pdsh_ss_server_cfg_t cfg;
    uint8_t cert[PDSH_CERT_MAX_DER];
} S;
static pdsh_ss_admission_t admission;
static uint64_t now_ms(void) { return (uint64_t)(esp_timer_get_time() / 1000); }

static int secure_coc_rx(struct ble_l2cap_chan *chan, struct os_mbuf **om) {
    uint8_t frame[SECURE_MTU];
    uint16_t len = OS_MBUF_PKTLEN(*om);
    xSemaphoreTake(secure_lock, portMAX_DELAY);
    pdsh_coc_close_t r = chan != S.chan ? PDSH_COC_CREDIT_OVERRUN : PDSH_COC_OK;
    if (r == PDSH_COC_OK) {
        /* Credits first: the receive path is not touched for a K-frame the
         * peer had no credit for. */
        if (S.coc.peer_credits == 0) r = pdsh_ss_coc_kframe(&S.coc, NULL, 0);
        else if (len > sizeof(frame)) r = pdsh_ss_coc_kframe(&S.coc, NULL, (size_t)S.coc.mps + 1);
        else if (os_mbuf_copydata(*om, 0, len, frame) != 0) r = PDSH_COC_KFRAME_SHORT;
        else r = pdsh_ss_coc_kframe(&S.coc, frame, len);
    }
    if (r != PDSH_COC_OK && !S.closing) {
        S.closing = true;
        ESP_LOGW("pdsh", "secure CoC closed: %s", pdsh_coc_close_name(r));
        ble_l2cap_disconnect(chan); /* the CoC only; the LE link stays */
    }
    xSemaphoreGive(secure_lock);
    return 0; /* the caller frees *om */
}

static int secure_coc_event(struct ble_l2cap_event *event, void *arg) {
    (void)arg;
    xSemaphoreTake(secure_lock, portMAX_DELAY);
    int rc = 0;
    switch (event->type) {
    case BLE_L2CAP_EVENT_COC_ACCEPT: {
        struct ble_l2cap_chan *chan = event->accept.chan;
        struct ble_gap_conn_desc desc;
        bool encrypted = ble_gap_conn_find(event->accept.conn_handle, &desc) == 0 && desc.sec_state.encrypted;
        if (!secure_available || !encrypted || S.chan || !pdsh_ss_admit(&admission, event->accept.conn_handle, now_ms()) ||
            !pdsh_ss_coc_init(&S.coc, SECURE_MTU, chan->my_coc_mps, (uint8_t)chan->coc_rx.credits)) {
            if (S.chan == NULL && admission.open && admission.conn_handle == event->accept.conn_handle)
                admission.open = false;
            rc = BLE_HS_ENOMEM; /* refused: second CoC, back-off, or unsupported layout */
            break;
        }
        chan->rx_fn = secure_coc_rx; /* before the response: no K-frame has arrived */
        memset(&S.tx, 0, sizeof(S.tx));
        S.chan = chan;
        S.conn_handle = event->accept.conn_handle;
        S.peer_mtu = event->accept.peer_sdu_size;
        S.accepted = true;
        S.opened = S.reached_open = S.closing = false;
        break;
    }
    case BLE_L2CAP_EVENT_COC_CONNECTED:
        if (event->connect.status) S.accepted = false;
        break;
    case BLE_L2CAP_EVENT_COC_TX_UNSTALLED:
        pdsh_ss_tx_unstalled(&S.tx, event->tx_unstalled.status);
        break;
    case BLE_L2CAP_EVENT_COC_DISCONNECTED:
        if (event->disconnect.chan == S.chan) {
            pdsh_ss_tx_disconnected(&S.tx); /* NimBLE frees a queued SDU in channel cleanup */
            S.chan = NULL;
            S.closing = true;
        }
        break;
    case BLE_L2CAP_EVENT_COC_DATA_RECEIVED:
        os_mbuf_free_chain(event->receive.sdu_rx); /* unreachable: rx_fn is replaced */
        break;
    default:
        break;
    }
    xSemaphoreGive(secure_lock);
    return rc;
}

static bool secure_random(uint8_t *out, size_t n) { return pdsh_entropy_random(out, n); }

/* Session task: TLS work never runs in the NimBLE host task. */
static void secure_task(void *arg) {
    (void)arg;
    static uint8_t sdu[SECURE_MTU];
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(20));
        xSemaphoreTake(secure_lock, portMAX_DELAY);
        uint64_t t = now_ms();
        if (S.accepted && !S.tls && !S.closing) {
            size_t len = 0;
            if (pdsh_cert_build(pdsh_identity_key(), true, S.cert, sizeof(S.cert), &len)) {
                S.cfg = (pdsh_ss_server_cfg_t){S.cert, len, pdsh_identity_key(), &pdsh_ss_timers_v2, secure_random};
                S.tls = pdsh_ss_conn_new(&S.cfg, t); /* <= 32 KiB, freed on close */
            }
            if (!S.tls) S.closing = true;
        }
        if (S.tls) {
            /* Consume SDUs only into free TLS input; credits follow consumption. */
            size_t ready;
            while ((ready = pdsh_ss_coc_ready(&S.coc)) && ready <= pdsh_ss_conn_rx_free(S.tls)) {
                uint8_t credits = 0;
                size_t n = pdsh_ss_coc_consume(&S.coc, sdu, sizeof(sdu), &credits);
                pdsh_ss_conn_rx(S.tls, sdu, n);
                if (S.chan && credits) ble_l2cap_sig_le_credits(S.conn_handle, S.chan->scid, credits);
            }
            if (!S.chan) pdsh_ss_conn_eof(S.tls);
            pdsh_ss_conn_state_t st = pdsh_ss_conn_poll(S.tls, t);
            if (st == PDSH_SS_CONN_OPEN) S.reached_open = true;
            /* Send path: one SDU at a time, waiting on BLE_HS_ESTALLED. */
            while (S.chan && pdsh_ss_tx_can_send(&S.tx)) {
                size_t cap = S.peer_mtu < sizeof(sdu) ? S.peer_mtu : sizeof(sdu);
                size_t n = pdsh_ss_conn_tx(S.tls, sdu, cap);
                if (!n) break;
                struct os_mbuf *om = ble_hs_mbuf_from_flat(sdu, n);
                int rc = om ? ble_l2cap_send(S.chan, om) : BLE_HS_ENOMEM;
                pdsh_tx_rc_t kind = rc == 0 ? PDSH_TX_RC_OK : rc == BLE_HS_ESTALLED ? PDSH_TX_RC_STALLED
                                    : (!om || rc == BLE_HS_EBUSY || rc == BLE_HS_EBADDATA) ? PDSH_TX_RC_NOT_TAKEN
                                                                                         : PDSH_TX_RC_FAILED;
                bool caller_frees;
                pdsh_ss_tx_sent(&S.tx, kind, &caller_frees);
                if (caller_frees && om) os_mbuf_free_chain(om);
            }
            if (S.tx.broken && S.chan && !S.closing) {
                S.closing = true;
                ble_l2cap_disconnect(S.chan);
            }
            if (st == PDSH_SS_CONN_CLOSED && S.chan && !S.closing && !S.tx.in_stack) {
                S.closing = true;
                ble_l2cap_disconnect(S.chan);
            }
        }
        if (S.accepted && S.closing && !S.chan) { /* channel gone: free everything */
            pdsh_ss_conn_free(S.tls);
            S.tls = NULL;
            pdsh_ss_released(&admission, S.reached_open, t);
            S.accepted = false;
            memset(&S.coc, 0, sizeof(S.coc));
        }
        xSemaphoreGive(secure_lock);
    }
}

/* Enrollment console (§3.2) on the primary console; authority needs the
 * 5 s arm hold, so an attached host alone can change nothing. */
static void console_line(const char *line) {
    printf("%s\n", line);
    fflush(stdout);
}
static uint64_t enroll_now(void) { return now_ms(); }
static bool indicator_available(void) {
    return CONFIG_PDSH_INDICATOR_GPIO >= 0 && CONFIG_PDSH_INDICATOR_GPIO != CONFIG_PDSH_LED_GPIO &&
           CONFIG_PDSH_INDICATOR_GPIO != CONFIG_PDSH_BUTTON_GPIO;
}
static pdsh_enroll_ops_t enroll_ops;
static void console_task(void *arg) {
    (void)arg;
    uint8_t buf[64];
    for (;;) {
        int n = 0;
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
        n = usb_serial_jtag_read_bytes(buf, sizeof(buf), pdMS_TO_TICKS(100));
#elif CONFIG_ESP_CONSOLE_UART
        n = uart_read_bytes(CONFIG_ESP_CONSOLE_UART_NUM, buf, sizeof(buf), pdMS_TO_TICKS(100));
#else
        vTaskDelay(pdMS_TO_TICKS(1000));
#endif
        if (n > 0) pdsh_enroll_feed(buf, (size_t)n);
        pdsh_enroll_tick();
    }
}
static void secure_start(void) {
    nvs_handle_t enr;
    enroll_ops = (pdsh_enroll_ops_t){enroll_now, pdsh_entropy_random, CONFIG_PDSH_BUTTON_GPIO >= 0,
                                     indicator_available(), console_line, pdsh_identity_probe,
                                     pdsh_identity_reset, NULL};
    ESP_ERROR_CHECK(nvs_open("pdsh_enr", NVS_READWRITE, &enr));
    pdsh_enroll_init(&enroll_ops, enr);
    if (indicator_available()) {
        int pin = CONFIG_PDSH_INDICATOR_GPIO < 0 ? 0 : CONFIG_PDSH_INDICATOR_GPIO;
        gpio_config_t config = {.pin_bit_mask = 1ULL << pin, .mode = GPIO_MODE_OUTPUT};
        ESP_ERROR_CHECK(gpio_config(&config));
        gpio_set_level(CONFIG_PDSH_INDICATOR_GPIO, 0);
    }
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
    usb_serial_jtag_driver_config_t usj = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usj));
#elif CONFIG_ESP_CONSOLE_UART
    if (!uart_is_driver_installed(CONFIG_ESP_CONSOLE_UART_NUM))
        ESP_ERROR_CHECK(uart_driver_install(CONFIG_ESP_CONSOLE_UART_NUM, 512, 0, 0, NULL, 0));
#endif
    xTaskCreate(console_task, "pdsh_enroll", 4096, NULL, 4, NULL);
    secure_lock = xSemaphoreCreateMutex();
    assert(secure_lock);
    xTaskCreate(secure_task, "pdsh_secure", 10240, NULL, 4, NULL);
}

static void io_task(void *arg) {
    (void)arg;
    message_t message;
    uint32_t seen_generation = 0;
    for (;;) {
        if (seen_generation != atomic_load(&generation)) {
            seen_generation = atomic_load(&generation);
            tools_reset_upload();
            app_caps = 0;
        }
        if (xQueueReceive(messages, &message, pdMS_TO_TICKS(30)) == pdTRUE) {
            if (message.generation != atomic_load(&generation) || !secure())
                continue;
            if (seen_generation != message.generation) {
                seen_generation = message.generation;
                tools_reset_upload();
                app_caps = 0;
            }
            uint8_t op = 0;
            uint16_t id = 0;
            const uint8_t *body = NULL;
            size_t n = 0;
            int err = pdsh_decode(message.data, message.len, &op, &id, &body, &n);
            uint8_t out[505];
            size_t count = 1;
            if (err) {
                if (atomic_load(&ready) && message.len >= 3) {
                    uint8_t nak[] = {err, message.data[0]};
                    notify_frame(0xff, u16(message.data + 1), nak, 2, message.generation);
                }
                continue;
            }
            if (!id)
                continue;
            if (op == 1) {
                if (n < 6 || !atomic_load(&tx_subscribed) || !atomic_load(&audio_subscribed))
                    continue;
                memset(out, 0, 33);
                out[0] = (u16(body) >> 8) == 1 ? 0 : 1;
                put16(out + 1, 0x0102);
                put32(out + 3, PDSH_CAP_TOOLS);
                put16(out + 7, ble_att_mtu(atomic_load(&connection)));
                out[9] = 1;
                put16(out + 10, 16000);
                out[12] = 60;
                out[13] = 16;
                out[14] = 1;
                put16(out + 15, 200);
                put32(out + 19, boot_id);
                put16(out + 23, 512);
                app_caps = u32(body + 2);
                count = 25;
                if (app_caps & PDSH_APP_TOOLS) {
                    memcpy(out + 25, "PDSH", 4);
                    put16(out + 29, 1);
                    put16(out + 31, 4096);
                    count = 33;
                }
                tools_reset_upload();
                tools_set_task_profile(app_caps);
                atomic_store(&ready, true);
                notify_frame(0x81, id, out, count, message.generation);
                if (!out[0]) {
                    status_info(out);
                    notify_frame(0x60, 0, out, 35, message.generation);
                } else
                    atomic_store(&ready, false);
            } else if (!atomic_load(&ready)) {
                // No notifications before HELLO, even for non-HELLO requests.
                continue;
            } else if (op == 2) {
                out[0] = 0;
                status_info(out + 1);
                notify_frame(0x82, id, out, 36, message.generation);
            } else if (op == 3) {
                out[0] = 14;
                notify_frame(0x83, id, out, 1, message.generation);
            } else if (op >= PDSH_UPLOAD && op <= PDSH_RESULT) {
                if (!(app_caps & PDSH_APP_TOOLS)) {
                    out[0] = 14;
                    count = 1;
                } else
                    count = tools_request(op, body, n, out);
                notify_frame(op | 0x80, id, out, count, message.generation);
            } else {
                uint8_t nak[] = {12, op};
                notify_frame(0xff, id, nak, 2, message.generation);
            }
        }
        if (indicator_available()) gpio_set_level(CONFIG_PDSH_INDICATOR_GPIO, pdsh_enroll_indicator_level(now_ms()));
        if (CONFIG_PDSH_BUTTON_GPIO >= 0) {
            bool pressed = gpio_get_level(CONFIG_PDSH_BUTTON_GPIO) == 0;
            /* The gesture classifier owns the button while armed (§3.3): the
             * ordinary meaning applies only to a press edge while locked. */
            if (pdsh_enroll_button(pressed) & PDSH_BUTTON_LEGACY_EDGE) {
                int bonds = 0;
                ble_store_util_count(BLE_STORE_OBJ_TYPE_PEER_SEC, &bonds);
                if (!bonds)
                    atomic_store(&pairing_until, esp_timer_get_time() + 60000000);
                if (atomic_load(&ready) && (app_caps & PDSH_APP_TOOLS)) {
                    if (++event_seq == 0)
                        ++event_seq;
                    char event[300];
                    int n = snprintf(
                        event, sizeof(event),
                        "{\"event_id\":\"%08lx-%08lx\",\"type\":\"button.pressed\",\"device_id\":"
                        "\"%s\",\"boot_id\":%lu,\"seq\":%lu,\"payload\":{}}",
                        (unsigned long)boot_id, (unsigned long)event_seq, tools_device_id(),
                        (unsigned long)boot_id, (unsigned long)event_seq);
                    notify_frame(PDSH_EVENT, 0, (uint8_t *)event, n, atomic_load(&generation));
                }
            }
        }
    }
}
static void host_task(void *arg) {
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}
static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    (void)data;
    if (base == WIFI_EVENT && (id == WIFI_EVENT_STA_START || id == WIFI_EVENT_STA_DISCONNECTED))
        esp_wifi_connect();
}
void app_main(void) {
    // Never erase NVS automatically: that would discard uncertain operations and bonds.
    ESP_ERROR_CHECK(nvs_flash_init());
    /* §2: the BLE controller (RF entropy) runs before any key is generated. */
    ESP_ERROR_CHECK(nimble_port_init());
    boot_id = esp_random();
    tools_init(boot_id);
    messages = xQueueCreate(8, sizeof(message_t));
    assert(messages);
    if (CONFIG_PDSH_BUTTON_GPIO >= 0) {
        gpio_config_t config = {.pin_bit_mask = 1ULL << CONFIG_PDSH_BUTTON_GPIO,
                                .mode = GPIO_MODE_INPUT,
                                .pull_up_en = GPIO_PULLUP_ENABLE};
        ESP_ERROR_CHECK(gpio_config(&config));
    }
    if (strlen(CONFIG_PDSH_WIFI_SSID)) {
        ESP_ERROR_CHECK(esp_netif_init());
        ESP_ERROR_CHECK(esp_event_loop_create_default());
        esp_netif_create_default_wifi_sta();
        wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
        ESP_ERROR_CHECK(esp_wifi_init(&init));
        ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
        wifi_config_t config = {0};
        strlcpy((char *)config.sta.ssid, CONFIG_PDSH_WIFI_SSID, sizeof(config.sta.ssid));
        strlcpy((char *)config.sta.password, CONFIG_PDSH_WIFI_PASSWORD,
                sizeof(config.sta.password));
        ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &config));
        ESP_ERROR_CHECK(esp_wifi_start());
    }
    ble_hs_cfg.sync_cb = sync_host;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_store_config_init();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("PDSH ESP32 Link");
    ESP_ERROR_CHECK(ble_gatts_count_cfg(services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(services));
    char fp[65];
    secure_available = pdsh_identity_probe(fp) == PDSH_IDENTITY_OK &&
                       ble_gatts_count_cfg(secure_services) == 0 && ble_gatts_add_svcs(secure_services) == 0 &&
                       ble_l2cap_create_server(SECURE_PSM, SECURE_MTU, secure_coc_event, NULL) == 0;
    /* §11.3: with the secure service the device key is no signing oracle. */
    tools_set_secure_service(secure_available);
    secure_start();
    int bonds = 0;
    ble_store_util_count(BLE_STORE_OBJ_TYPE_PEER_SEC, &bonds);
    atomic_store(&pairing_until, !bonds ? esp_timer_get_time() + 60000000 : 0);
    xTaskCreate(io_task, "pdsh_link", 8192, NULL, 5, NULL);
    nimble_port_freertos_init(host_task);
}

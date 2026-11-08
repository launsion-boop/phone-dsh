idf_component_register(SRCS "main.c" "link_tools.c" "pdsh_identity.c" "pdsh_task_validate.c" "pdsh_task_store.c"
    "pdsh_enroll.c" "pdsh_secure_msg.c" "pdsh_secure_cert.c" "pdsh_secure_session.c" INCLUDE_DIRS "."
    REQUIRES bt nvs_flash bootloader_support esp_driver_uart esp_driver_usb_serial_jtag esp_wifi esp_event esp_netif esp_timer esp_driver_gpio esp_hw_support mbedtls pdsh_link_wire pdsh_home espressif__cjson)
# §5 credit mechanism: main.c replaces the CoC receive function of the pinned
# NimBLE (ESP-IDF v6.1 fff9895c) and needs its private L2CAP headers.
target_include_directories(${COMPONENT_LIB} PRIVATE
    "$ENV{IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/src")

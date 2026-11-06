idf_component_register(SRCS "main.c" "link_tools.c" "pdsh_task_validate.c" INCLUDE_DIRS "."
    REQUIRES bt nvs_flash esp_wifi esp_event esp_netif esp_timer esp_driver_gpio esp_hw_support mbedtls pdsh_link_wire pdsh_home espressif__cjson)

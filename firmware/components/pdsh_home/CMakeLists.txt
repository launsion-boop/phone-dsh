idf_component_register(SRCS "pdsh_home.c" "vendor/xl_home_policy.c" "pdsh_home_transport.c"
    INCLUDE_DIRS "include" "vendor/include"
    REQUIRES espressif__cjson
    PRIV_REQUIRES esp_http_client tcp_transport lwip esp_timer esp_hw_support)

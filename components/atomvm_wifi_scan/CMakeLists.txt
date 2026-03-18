idf_component_register(
    SRCS "src/atomvm_wifi_scan.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES esp_wifi nvs_flash libatomvm
    WHOLE_ARCHIVE
)

idf_component_register(
    SRCS "src/atomvm_ota.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES nvs_flash spi_flash esp_partition libatomvm
    WHOLE_ARCHIVE
)

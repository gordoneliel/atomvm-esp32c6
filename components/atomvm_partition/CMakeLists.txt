idf_component_register(
    SRCS "src/atomvm_partition.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES nvs_flash spi_flash esp_partition libatomvm
    REQUIRES atomvm_boot_env
    WHOLE_ARCHIVE
)

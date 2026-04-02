idf_component_register(
    SRCS "src/atomvm_boot_env.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES nvs_flash libatomvm app_update esp_partition
    WHOLE_ARCHIVE
)

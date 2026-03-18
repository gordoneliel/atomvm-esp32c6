idf_component_register(
    SRCS "src/atomvm_ble.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES bt nvs_flash libatomvm
)

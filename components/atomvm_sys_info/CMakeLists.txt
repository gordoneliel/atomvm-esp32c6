idf_component_register(
    SRCS "src/atomvm_sys_info.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES libatomvm esp_timer
    WHOLE_ARCHIVE
)

idf_component_register(
    SRCS "src/atomvm_websocket.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES esp_websocket_client esp_event libatomvm
    WHOLE_ARCHIVE
)

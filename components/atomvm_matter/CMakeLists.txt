idf_component_register(
    SRCS "src/atomvm_matter.cpp"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES esp_matter nvs_flash openthread libatomvm
    WHOLE_ARCHIVE
)

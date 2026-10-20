idf_component_register(
    SRCS "src/atomvm_led_strip.c"
    INCLUDE_DIRS "src"
    PRIV_REQUIRES led_strip libatomvm
    WHOLE_ARCHIVE
)

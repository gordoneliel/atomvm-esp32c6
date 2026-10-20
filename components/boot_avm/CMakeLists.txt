# Adds AtomVM's elixir_esp32boot.avm to `idf.py flash`, writing it to the boot.avm
# partition. AtomVM's build only does this itself when main.avm is at its
# default offset (0x250000), which the Matter firmware is too large for.
idf_component_register()

if(NOT CMAKE_BUILD_EARLY_EXPANSION)
    if(NOT EXISTS "${FIREFLY_BOOT_AVM}")
        message(FATAL_ERROR "elixir_esp32boot.avm not found at '${FIREFLY_BOOT_AVM}', build with firmware/idf.sh")
    endif()
    partition_table_get_partition_info(boot_avm_offset "--partition-name boot.avm" "offset")
    esptool_py_flash_target_image(flash boot.avm "${boot_avm_offset}" "${FIREFLY_BOOT_AVM}")
endif()

/*
 * atomvm_ota.c - A/B OTA NIF for AtomVM on ESP32
 *
 * Works with the custom main.c boot slot logic. NVS namespace "ota" stores:
 *   "active" (u8) - 0 = avm_a, 1 = avm_b
 *   "boots"  (u8) - boot attempt counter (reset by mark_valid)
 *
 * NIFs:
 *   ota_nif:mark_valid/0 - reset boot counter to 0
 *   ota_nif:begin/1      - erase inactive partition (takes size in bytes)
 *   ota_nif:write_chunk/2 - write chunk at offset to inactive partition
 *   ota_nif:swap/0        - switch active slot and reboot
 */

#include <string.h>

#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

#include <esp_log.h>
#include <esp_partition.h>
#include <esp_system.h>
#include <nvs.h>
#include <nvs_flash.h>

#define TAG "OTA_NIF"

/* Get the inactive partition name based on NVS "active" value */
static const char *get_inactive_part_name(void)
{
    nvs_handle_t nvs;
    uint8_t active = 0;
    if (nvs_open("ota", NVS_READONLY, &nvs) == ESP_OK) {
        nvs_get_u8(nvs, "active", &active);
        nvs_close(nvs);
    }
    return active ? "avm_a" : "avm_b";
}

/*
 * ota_nif:mark_valid/0
 * Reset boot counter to 0 in NVS.
 */
static term nif_mark_valid(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    nvs_handle_t nvs;
    esp_err_t err = nvs_open("ota", NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        RAISE_ERROR(globalcontext_make_atom(ctx->global, ATOM_STR("\x3", "nvs")));
    }

    nvs_set_u8(nvs, "boots", 0);
    nvs_commit(nvs);
    nvs_close(nvs);

    ESP_LOGI(TAG, "Boot marked valid (counter reset)");
    return OK_ATOM;
}

/*
 * ota_nif:begin/1
 * Erase the inactive partition. Takes expected size (unused, partition is fully erased).
 * Returns :ok or {:error, reason}.
 */
static term nif_begin(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    GlobalContext *glb = ctx->global;

    int64_t size = term_to_int(argv[0]);
    const char *part_name = get_inactive_part_name();

    ESP_LOGI(TAG, "begin: erasing partition '%s' for %lld bytes", part_name, (long long)size);

    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, part_name);
    if (part == NULL) {
        ESP_LOGE(TAG, "partition '%s' not found", part_name);
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x9", "not_found")));
        return t;
    }

    esp_err_t err = esp_partition_erase_range(part, 0, part->size);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "erase failed: %s", esp_err_to_name(err));
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x5", "erase")));
        return t;
    }

    ESP_LOGI(TAG, "partition '%s' erased (%ld bytes)", part_name, (long)part->size);
    return OK_ATOM;
}

/*
 * ota_nif:write_chunk/2
 * Write binary data at given offset to inactive partition.
 */
static term nif_write_chunk(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    GlobalContext *glb = ctx->global;

    int64_t offset = term_to_int(argv[0]);
    term bin = argv[1];
    size_t len = term_binary_size(bin);
    const char *data = term_binary_data(bin);

    const char *part_name = get_inactive_part_name();
    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, part_name);

    if (part == NULL) {
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x9", "not_found")));
        return t;
    }

    esp_err_t err = esp_partition_write(part, (size_t)offset, data, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "write at offset %lld failed: %s", (long long)offset, esp_err_to_name(err));
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x5", "write")));
        return t;
    }

    return OK_ATOM;
}

/*
 * ota_nif:swap/0
 * Toggle active slot in NVS, reset boot counter, and reboot.
 */
static term nif_swap(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    nvs_handle_t nvs;
    esp_err_t err = nvs_open("ota", NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        RAISE_ERROR(globalcontext_make_atom(ctx->global, ATOM_STR("\x3", "nvs")));
    }

    uint8_t active = 0;
    nvs_get_u8(nvs, "active", &active);
    uint8_t new_active = active ? 0 : 1;

    nvs_set_u8(nvs, "active", new_active);
    nvs_set_u8(nvs, "boots", 0);
    nvs_commit(nvs);
    nvs_close(nvs);

    ESP_LOGI(TAG, "Swapping from %s to %s, rebooting...",
             active ? "avm_b" : "avm_a",
             new_active ? "avm_b" : "avm_a");

    esp_restart();

    /* Never reached */
    return OK_ATOM;
}

/* NIF registration */

static const struct Nif mark_valid_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_mark_valid
};

static const struct Nif begin_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_begin
};

static const struct Nif write_chunk_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_write_chunk
};

static const struct Nif swap_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_swap
};

void atomvm_ota_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_ota component loaded");
}

const struct Nif *atomvm_ota_nif_get_nif(const char *nifname)
{
    if (strcmp("ota_nif:mark_valid/0", nifname) == 0) {
        return &mark_valid_nif;
    }
    if (strcmp("ota_nif:begin/1", nifname) == 0) {
        return &begin_nif;
    }
    if (strcmp("ota_nif:write_chunk/2", nifname) == 0) {
        return &write_chunk_nif;
    }
    if (strcmp("ota_nif:swap/0", nifname) == 0) {
        return &swap_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_ota, atomvm_ota_nif_init, NULL, atomvm_ota_nif_get_nif)

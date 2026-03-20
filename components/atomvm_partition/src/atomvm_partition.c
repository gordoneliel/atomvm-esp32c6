/*
 * atomvm_partition.c - Partition read/write NIF for AtomVM on ESP32
 *
 * Handles erasing and writing to the inactive partition.
 * Uses atomvm_boot_env for partition name resolution.
 *
 * NIFs:
 *   partition_nif:begin/1      - erase inactive partition (takes size in bytes)
 *   partition_nif:write_chunk/2 - write chunk at offset to inactive partition
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
#include <nvs.h>
#include <nvs_flash.h>

#include "atomvm_boot_env.h"

#define TAG "PARTITION_NIF"

/*
 * partition_nif:begin/1
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
 * partition_nif:write_chunk/2
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

/* NIF registration */

static const struct Nif begin_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_begin
};

static const struct Nif write_chunk_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_write_chunk
};

void atomvm_partition_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_partition component loaded");
}

const struct Nif *atomvm_partition_nif_get_nif(const char *nifname)
{
    if (strcmp("partition_nif:begin/1", nifname) == 0) {
        return &begin_nif;
    }
    if (strcmp("partition_nif:write_chunk/2", nifname) == 0) {
        return &write_chunk_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_partition, atomvm_partition_nif_init, NULL, atomvm_partition_nif_get_nif)

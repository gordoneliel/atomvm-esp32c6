/*
 * atomvm_partition.c - Partition read/write NIF for AtomVM on ESP32
 *
 * NIFs:
 *   partition_nif:begin/1       - erase inactive AVM partition (legacy)
 *   partition_nif:write_chunk/2 - write to inactive AVM partition (legacy)
 *   partition_nif:erase/2       - erase any partition by name
 *   partition_nif:write/3       - write to any partition by name
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

/* ── Helpers ── */

static term make_error(Context *ctx, const char *reason)
{
    size_t rlen = strlen(reason);
    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term t = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(t, 0, ERROR_ATOM);
    char atom_buf[32];
    atom_buf[0] = (char)(rlen > 30 ? 30 : rlen);
    memcpy(atom_buf + 1, reason, (size_t)atom_buf[0]);
    term_put_tuple_element(t, 1,
        globalcontext_make_atom(ctx->global, atom_buf));
    return t;
}

static const esp_partition_t *find_partition(const char *name)
{
    const esp_partition_t *p = esp_partition_find_first(
        ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, name);
    if (!p) {
        p = esp_partition_find_first(
            ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, name);
    }
    return p;
}

static void extract_name(term bin, char *out, size_t max)
{
    int len = term_binary_size(bin);
    if ((size_t)len >= max) len = (int)max - 1;
    memcpy(out, term_binary_data(bin), len);
    out[len] = '\0';
}

/* ── Legacy NIFs (inactive AVM partition) ── */

static term nif_begin(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    int64_t size = term_to_int(argv[0]);
    const char *part_name = get_inactive_part_name();

    ESP_LOGI(TAG, "begin: erasing '%s' for %lld bytes", part_name, (long long)size);

    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, part_name);
    if (!part) {
        ESP_LOGE(TAG, "partition '%s' not found", part_name);
        return make_error(ctx, "not_found");
    }

    esp_err_t err = esp_partition_erase_range(part, 0, part->size);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "erase failed: %s", esp_err_to_name(err));
        return make_error(ctx, "erase");
    }

    ESP_LOGI(TAG, "'%s' erased (%ld bytes)", part_name, (long)part->size);
    return OK_ATOM;
}

static term nif_write_chunk(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    int64_t offset = term_to_int(argv[0]);
    size_t len = term_binary_size(argv[1]);
    const char *data = term_binary_data(argv[1]);

    const char *part_name = get_inactive_part_name();
    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, part_name);
    if (!part) {
        return make_error(ctx, "not_found");
    }

    esp_err_t err = esp_partition_write(part, (size_t)offset, data, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "write at %lld failed: %s", (long long)offset, esp_err_to_name(err));
        return make_error(ctx, "write");
    }

    return OK_ATOM;
}

/* ── Generic NIFs (any partition by name) ── */

/*
 * partition_nif:erase/2 - Erase partition by name
 * Args: name (binary), size (integer)
 */
static term nif_erase(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (!term_is_binary(argv[0]) || !term_is_integer(argv[1])) {
        RAISE_ERROR(BADARG_ATOM);
    }

    char name[64];
    extract_name(argv[0], name, sizeof(name));

    const esp_partition_t *part = find_partition(name);
    if (!part) {
        ESP_LOGE(TAG, "'%s' not found", name);
        return make_error(ctx, "not_found");
    }

    esp_err_t err = esp_partition_erase_range(part, 0, part->size);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "erase '%s' failed: %s", name, esp_err_to_name(err));
        return make_error(ctx, "erase");
    }

    ESP_LOGI(TAG, "Erased '%s' (%ld bytes)", name, (long)part->size);
    return OK_ATOM;
}

/*
 * partition_nif:write/3 - Write to partition by name
 * Args: name (binary), offset (integer), data (binary)
 */
static term nif_write(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (!term_is_binary(argv[0]) || !term_is_integer(argv[1]) || !term_is_binary(argv[2])) {
        RAISE_ERROR(BADARG_ATOM);
    }

    char name[64];
    extract_name(argv[0], name, sizeof(name));

    uint32_t offset = (uint32_t)term_to_int(argv[1]);
    const uint8_t *data = (const uint8_t *)term_binary_data(argv[2]);
    size_t len = term_binary_size(argv[2]);

    const esp_partition_t *part = find_partition(name);
    if (!part) {
        return make_error(ctx, "not_found");
    }

    esp_err_t err = esp_partition_write(part, offset, data, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "write '%s' at %lu failed: %s", name,
                 (unsigned long)offset, esp_err_to_name(err));
        return make_error(ctx, "write");
    }

    return OK_ATOM;
}

/* ── NIF registration ── */

static const struct Nif begin_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_begin };
static const struct Nif write_chunk_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_write_chunk };
static const struct Nif erase_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_erase };
static const struct Nif write_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_write };

void atomvm_partition_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_partition component loaded");
}

const struct Nif *atomvm_partition_nif_get_nif(const char *nifname)
{
    if (strcmp("partition_nif:begin/1", nifname) == 0) return &begin_nif;
    if (strcmp("partition_nif:write_chunk/2", nifname) == 0) return &write_chunk_nif;
    if (strcmp("partition_nif:erase/2", nifname) == 0) return &erase_nif;
    if (strcmp("partition_nif:write/3", nifname) == 0) return &write_nif;
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_partition, atomvm_partition_nif_init, NULL, atomvm_partition_nif_get_nif)

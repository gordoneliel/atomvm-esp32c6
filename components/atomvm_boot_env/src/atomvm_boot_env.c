/*
 * atomvm_boot_env.c - Boot environment NIF for AtomVM on ESP32
 *
 * Manages A/B boot slot metadata in NVS namespace "ota":
 *   "active" (u8) - 0 = main_a/ota_0, 1 = main_b/ota_1
 *   "boots"  (u8) - boot attempt counter (reset by mark_valid)
 *
 * NIFs:
 *   boot_env_nif:mark_valid/0  - reset boot counter to 0
 *   boot_env_nif:swap/0        - toggle active slot and reboot (legacy)
 *   boot_env_nif:activate/1    - set specific slot (0 or 1), update NVS + otadata
 *   boot_env_nif:active_slot/0 - return current active slot (0 or 1)
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
#include <esp_ota_ops.h>
#include <esp_partition.h>
#include <esp_system.h>
#include <nvs.h>
#include <nvs_flash.h>

#include "atomvm_boot_env.h"

#define TAG "BOOT_ENV"

/* ── Shared helpers ── */

static uint8_t get_active(void)
{
    nvs_handle_t nvs;
    uint8_t active = 0;
    if (nvs_open("ota", NVS_READONLY, &nvs) == ESP_OK) {
        nvs_get_u8(nvs, "active", &active);
        nvs_close(nvs);
    }
    return active;
}

const char *get_inactive_part_name(void)
{
    return get_active() ? "main_a" : "main_b";
}

/* ── NIFs ── */

/*
 * boot_env_nif:mark_valid/0
 */
static term nif_mark_valid(Context *ctx, int argc, term argv[])
{
    UNUSED(argc); UNUSED(argv);

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
 * boot_env_nif:swap/0 (legacy — toggle and reboot)
 */
static term nif_swap(Context *ctx, int argc, term argv[])
{
    UNUSED(argc); UNUSED(argv);

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

    /* Also update otadata for firmware slot */
    const char *app_name = new_active ? "ota_1" : "ota_0";
    const esp_partition_t *app_part = esp_partition_find_first(
        ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, app_name);
    if (app_part) {
        esp_ota_set_boot_partition(app_part);
    }

    ESP_LOGI(TAG, "Swapping from slot %d to %d, rebooting...", active, new_active);
    esp_restart();
    return OK_ATOM;
}

/*
 * boot_env_nif:activate/1 - Set specific slot
 * Args: slot (0 or 1)
 * Sets NVS "active" + esp_ota_set_boot_partition. Does NOT reboot.
 */
static term nif_activate(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    int slot = term_to_int(argv[0]);
    if (slot != 0 && slot != 1) {
        RAISE_ERROR(BADARG_ATOM);
    }

    /* Update NVS */
    nvs_handle_t nvs;
    if (nvs_open("ota", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_set_u8(nvs, "active", (uint8_t)slot);
        nvs_set_u8(nvs, "boots", 0);
        nvs_commit(nvs);
        nvs_close(nvs);
    }

    /* Update otadata for firmware slot */
    const char *app_name = slot ? "ota_1" : "ota_0";
    const esp_partition_t *app_part = esp_partition_find_first(
        ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, app_name);
    if (app_part) {
        esp_err_t err = esp_ota_set_boot_partition(app_part);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "esp_ota_set_boot_partition failed: %s", esp_err_to_name(err));
        }
    }

    ESP_LOGI(TAG, "Activated slot %d (firmware=%s, avm=%s)",
             slot, app_name, slot ? "main_b" : "main_a");
    return OK_ATOM;
}

/*
 * boot_env_nif:active_slot/0 - Return current active slot
 */
static term nif_active_slot(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx); UNUSED(argc); UNUSED(argv);
    return term_from_int(get_active());
}

/* ── NIF registration ── */

static const struct Nif mark_valid_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_mark_valid };
static const struct Nif swap_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_swap };
static const struct Nif activate_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_activate };
static const struct Nif active_slot_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_active_slot };

void atomvm_boot_env_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_boot_env component loaded");
}

const struct Nif *atomvm_boot_env_nif_get_nif(const char *nifname)
{
    if (strcmp("boot_env_nif:mark_valid/0", nifname) == 0) return &mark_valid_nif;
    if (strcmp("boot_env_nif:swap/0", nifname) == 0) return &swap_nif;
    if (strcmp("boot_env_nif:activate/1", nifname) == 0) return &activate_nif;
    if (strcmp("boot_env_nif:active_slot/0", nifname) == 0) return &active_slot_nif;
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_boot_env, atomvm_boot_env_nif_init, NULL, atomvm_boot_env_nif_get_nif)

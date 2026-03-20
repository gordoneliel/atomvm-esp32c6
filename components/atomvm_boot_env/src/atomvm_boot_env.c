/*
 * atomvm_boot_env.c - Boot environment NIF for AtomVM on ESP32
 *
 * Manages A/B boot slot metadata in NVS namespace "ota":
 *   "active" (u8) - 0 = avm_a, 1 = avm_b
 *   "boots"  (u8) - boot attempt counter (reset by mark_valid)
 *
 * NIFs:
 *   boot_env_nif:mark_valid/0 - reset boot counter to 0
 *   boot_env_nif:swap/0       - switch active slot and reboot
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
#include <esp_system.h>
#include <nvs.h>
#include <nvs_flash.h>

#include "atomvm_boot_env.h"

#define TAG "BOOT_ENV"

const char *get_inactive_part_name(void)
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
 * boot_env_nif:mark_valid/0
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
 * boot_env_nif:swap/0
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

static const struct Nif swap_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_swap
};

void atomvm_boot_env_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_boot_env component loaded");
}

const struct Nif *atomvm_boot_env_nif_get_nif(const char *nifname)
{
    if (strcmp("boot_env_nif:mark_valid/0", nifname) == 0) {
        return &mark_valid_nif;
    }
    if (strcmp("boot_env_nif:swap/0", nifname) == 0) {
        return &swap_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_boot_env, atomvm_boot_env_nif_init, NULL, atomvm_boot_env_nif_get_nif)

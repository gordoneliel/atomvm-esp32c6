/*
 * atomvm_wifi_scan.c - WiFi scanning NIF for AtomVM on ESP32
 *
 * Provides wifi_scan_nif:scan/0 which performs a blocking WiFi scan
 * and returns a list of nearby access points as proplists:
 *
 *   [{ssid, <<"MyNetwork">>}, {rssi, -45}, {channel, 6}, {authmode, wpa2_psk}]
 *
 * WiFi must already be initialized (e.g., via network driver in managed mode)
 * before calling scan/0.
 */

#include <string.h>
#include <stdlib.h>

/* AtomVM headers */
#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

/* ESP-IDF headers */
#include <esp_log.h>
#include <esp_wifi.h>

#define TAG "WiFi_Scan_NIF"
#define MAX_SCAN_RESULTS 20

static const char *authmode_str(wifi_auth_mode_t mode)
{
    switch (mode) {
        case WIFI_AUTH_OPEN:            return "open";
        case WIFI_AUTH_WEP:             return "wep";
        case WIFI_AUTH_WPA_PSK:         return "wpa_psk";
        case WIFI_AUTH_WPA2_PSK:        return "wpa2_psk";
        case WIFI_AUTH_WPA_WPA2_PSK:    return "wpa_wpa2_psk";
        case WIFI_AUTH_WPA3_PSK:        return "wpa3_psk";
        case WIFI_AUTH_WPA2_WPA3_PSK:   return "wpa2_wpa3_psk";
        default:                        return "unknown";
    }
}

/*
 * Heap needed per AP entry:
 *   4 x {Key, Value} tuples = 4 * TUPLE_SIZE(2) = 4 * 3 = 12
 *   4 cons cells for the inner proplist = 4 * CONS_SIZE = 4 * 2 = 8
 *   1 binary for SSID (up to 33 bytes) = TERM_BINARY_HEAP_SIZE(33) ~ 12
 *   1 cons cell for the outer list = CONS_SIZE = 2
 *   Total per AP ~ 34
 *
 *   Plus atoms: ssid, rssi, channel, authmode, and authmode values.
 *   Atoms are interned globally, no heap cost.
 */
#define HEAP_PER_AP (4 * TUPLE_SIZE(2) + 4 * CONS_SIZE + TERM_BINARY_HEAP_SIZE(33) + CONS_SIZE)

static term nif_wifi_scan(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    GlobalContext *glb = ctx->global;

    /* Perform blocking scan */
    wifi_scan_config_t scan_config = {
        .ssid = NULL,
        .bssid = NULL,
        .channel = 0,
        .show_hidden = true,
        .scan_type = WIFI_SCAN_TYPE_ACTIVE,
        .scan_time = {
            .active = { .min = 100, .max = 300 },
        },
    };

    esp_err_t err = esp_wifi_scan_start(&scan_config, true);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "scan_start failed: %s", esp_err_to_name(err));
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term error_tuple = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(error_tuple, 0, ERROR_ATOM);
        term_put_tuple_element(error_tuple, 1, globalcontext_make_atom(glb, ATOM_STR("\x4", "scan")));
        return error_tuple;
    }

    uint16_t ap_count = 0;
    esp_wifi_scan_get_ap_num(&ap_count);
    if (ap_count > MAX_SCAN_RESULTS) {
        ap_count = MAX_SCAN_RESULTS;
    }

    ESP_LOGI(TAG, "Found %d access points", ap_count);

    if (ap_count == 0) {
        return term_nil();
    }

    wifi_ap_record_t *records = malloc(sizeof(wifi_ap_record_t) * ap_count);
    if (records == NULL) {
        esp_wifi_scan_get_ap_records(&ap_count, NULL); /* clear scan results */
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    esp_wifi_scan_get_ap_records(&ap_count, records);

    /* Ensure enough heap for all AP entries */
    size_t needed = (size_t)ap_count * HEAP_PER_AP;
    if (UNLIKELY(memory_ensure_free(ctx, needed) != MEMORY_GC_OK)) {
        free(records);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    /* Pre-intern atoms */
    term atom_ssid = globalcontext_make_atom(glb, ATOM_STR("\x4", "ssid"));
    term atom_rssi = globalcontext_make_atom(glb, ATOM_STR("\x4", "rssi"));
    term atom_channel = globalcontext_make_atom(glb, ATOM_STR("\x7", "channel"));
    term atom_authmode = globalcontext_make_atom(glb, ATOM_STR("\x8", "authmode"));

    /* Build list from back to front */
    term result = term_nil();

    for (int i = ap_count - 1; i >= 0; i--) {
        wifi_ap_record_t *ap = &records[i];

        /* SSID binary */
        size_t ssid_len = strlen((const char *)ap->ssid);
        term ssid_bin = term_from_literal_binary(ap->ssid, ssid_len, &ctx->heap, glb);

        /* Authmode atom */
        const char *auth_str = authmode_str(ap->authmode);
        size_t auth_len = strlen(auth_str);
        char atom_buf[20];
        atom_buf[0] = (char)auth_len;
        memcpy(atom_buf + 1, auth_str, auth_len);
        term atom_auth_val = globalcontext_make_atom(glb, atom_buf);

        /* Build proplist: [{ssid, Bin}, {rssi, Int}, {channel, Int}, {authmode, Atom}] */
        /* Build from tail to head */
        term inner = term_nil();

        /* {authmode, atom} */
        term t4 = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t4, 0, atom_authmode);
        term_put_tuple_element(t4, 1, atom_auth_val);
        inner = term_list_prepend(t4, inner, &ctx->heap);

        /* {channel, int} */
        term t3 = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t3, 0, atom_channel);
        term_put_tuple_element(t3, 1, term_from_int(ap->primary));
        inner = term_list_prepend(t3, inner, &ctx->heap);

        /* {rssi, int} */
        term t2 = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t2, 0, atom_rssi);
        term_put_tuple_element(t2, 1, term_from_int(ap->rssi));
        inner = term_list_prepend(t2, inner, &ctx->heap);

        /* {ssid, binary} */
        term t1 = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t1, 0, atom_ssid);
        term_put_tuple_element(t1, 1, ssid_bin);
        inner = term_list_prepend(t1, inner, &ctx->heap);

        /* Prepend this AP's proplist to the outer result list */
        result = term_list_prepend(inner, result, &ctx->heap);
    }

    free(records);
    return result;
}

/* ===========================================================================
 * NIF registration
 * =========================================================================== */

static const struct Nif wifi_scan_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_wifi_scan
};

void atomvm_wifi_scan_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_wifi_scan component loaded");
}

const struct Nif *atomvm_wifi_scan_nif_get_nif(const char *nifname)
{
    if (strcmp("wifi_scan_nif:scan/0", nifname) == 0) {
        return &wifi_scan_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_wifi_scan, atomvm_wifi_scan_nif_init, NULL, atomvm_wifi_scan_nif_get_nif)

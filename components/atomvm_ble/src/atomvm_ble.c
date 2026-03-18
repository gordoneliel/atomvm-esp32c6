/*
 * atomvm_ble.c - BLE peripheral NIF for AtomVM on ESP32-C6
 *
 * Provides a minimal BLE peripheral (GATT server) interface:
 *   ble_nif:init/1       - Initialize NimBLE stack
 *   ble_nif:add_service/2 - Register a GATT service with characteristics
 *   ble_nif:advertise/0  - Start BLE advertising
 *   ble_nif:notify/3     - Send a GATT notification
 *
 * BLE events are delivered as messages to the calling process:
 *   {:ble_connected, conn_handle}
 *   {:ble_disconnected, reason}
 *   {:ble_subscribed, char_handle}
 *   {:ble_write, char_handle, data}
 */

#include <sdkconfig.h>

#include <stdbool.h>
#include <string.h>

/* AtomVM headers */
#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <erl_nif.h>
#include <globalcontext.h>
#include <interop.h>
#include <mailbox.h>
#include <memory.h>
#include <nifs.h>
#include <port.h>
#include <portnifloader.h>
#include <term.h>

/* ESP-IDF / NimBLE headers */
#include <esp_log.h>
#include <nvs_flash.h>
#include <nimble/nimble_port.h>
#include <nimble/nimble_port_freertos.h>
#include <host/ble_hs.h>
#include <host/ble_gap.h>
#include <host/util/util.h>
#include <services/gap/ble_svc_gap.h>
#include <services/gatt/ble_svc_gatt.h>

#define TAG "atomvm_ble"
#define MAX_CHARACTERISTICS 8

/* ---------------------------------------------------------------------------
 * Module state
 * --------------------------------------------------------------------------- */

static GlobalContext *s_global = NULL;
static int32_t s_owner_pid = -1;          /* Erlang PID that called init/1 */
static uint16_t s_conn_handle = 0;
static bool s_connected = false;

static char s_device_name[32] = "atomvm";

/* Characteristic value handles (populated after service registration) */
static uint16_t s_chr_val_handles[MAX_CHARACTERISTICS];
static int s_chr_count = 0;

/* ---------------------------------------------------------------------------
 * Forward declarations
 * --------------------------------------------------------------------------- */

static int ble_gap_event_cb(struct ble_gap_event *event, void *arg);
static void ble_on_sync(void);
static void ble_host_task(void *param);
static void start_advertising(void);

/* ---------------------------------------------------------------------------
 * Helper: send a message to the owner Erlang process from a FreeRTOS task
 *
 * Uses port_send_message_from_task which is safe for cross-thread messaging.
 * --------------------------------------------------------------------------- */

static inline term make_atom(GlobalContext *global, AtomString atom_str)
{
    return globalcontext_make_atom(global, atom_str);
}

static void send_event_to_owner_2(term a, term b)
{
    if (s_owner_pid < 0 || s_global == NULL) return;

    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2), heap);
    {
        term msg = port_heap_create_tuple2(&heap, a, b);
        port_send_message_from_task(s_global,
            term_from_local_process_id(s_owner_pid), msg);
    }
    END_WITH_STACK_HEAP(heap, s_global);
}

/* ---------------------------------------------------------------------------
 * GATT access callback — handles reads and writes to characteristics
 * --------------------------------------------------------------------------- */

static int gatt_chr_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
        ESP_LOGI(TAG, "GATT read on handle %d", attr_handle);
        /* Return empty data for now — app can override via notify */
        break;

    case BLE_GATT_ACCESS_OP_WRITE_CHR: {
        ESP_LOGI(TAG, "GATT write on handle %d, len=%d",
                 attr_handle, OS_MBUF_PKTLEN(ctxt->om));

        /* TODO: Build {:ble_write, char_handle, data} tuple and send to owner
         * This requires allocating on the process heap, which needs
         * careful handling with AtomVM's memory model.
         * For now, just log it. */
        break;
    }

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }

    return 0;
}

/* ---------------------------------------------------------------------------
 * GATT service definition
 *
 * For simplicity we define one custom service with one notify characteristic.
 * A production version would build this dynamically from the Erlang-side
 * add_service/2 call.
 * --------------------------------------------------------------------------- */

/* Custom 128-bit UUIDs for radar data service */
static const ble_uuid128_t radar_svc_uuid =
    BLE_UUID128_INIT(0xFB, 0x34, 0x9B, 0x5F, 0x00, 0x80, 0x00, 0x80,
                     0x00, 0x10, 0x00, 0x01, 0x12, 0x3A, 0xB8, 0xDF);

static const ble_uuid128_t radar_chr_uuid =
    BLE_UUID128_INIT(0xFB, 0x34, 0x9B, 0x5F, 0x00, 0x80, 0x00, 0x80,
                     0x00, 0x10, 0x00, 0x01, 0x13, 0x3A, 0xB8, 0xDF);

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &radar_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &radar_chr_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .val_handle = &s_chr_val_handles[0],
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 } /* terminator */
        },
    },
    { 0 } /* terminator */
};

/* ---------------------------------------------------------------------------
 * GAP event handler
 * --------------------------------------------------------------------------- */

static int ble_gap_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            s_connected = true;
            ESP_LOGI(TAG, "Client connected, handle=%d", s_conn_handle);

            send_event_to_owner_2(
                make_atom(s_global, ATOM_STR("\xD", "ble_connected")),
                term_from_int(s_conn_handle));
        } else {
            ESP_LOGW(TAG, "Connection failed, status=%d", event->connect.status);
            start_advertising();
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        s_connected = false;
        ESP_LOGI(TAG, "Client disconnected, reason=%d",
                 event->disconnect.reason);

        send_event_to_owner_2(
            make_atom(s_global, ATOM_STR("\x10", "ble_disconnected")),
            term_from_int(event->disconnect.reason));
        start_advertising();
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "Subscribe event: cur_notify=%d, attr_handle=%d",
                 event->subscribe.cur_notify, event->subscribe.attr_handle);

        if (event->subscribe.cur_notify) {
            send_event_to_owner_2(
                make_atom(s_global, ATOM_STR("\xE", "ble_subscribed")),
                term_from_int(event->subscribe.attr_handle));
        }
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(TAG, "Advertising complete");
        start_advertising();
        break;

    default:
        break;
    }

    return 0;
}

/* ---------------------------------------------------------------------------
 * Advertising
 * --------------------------------------------------------------------------- */

static void start_advertising(void)
{
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)s_device_name;
    fields.name_len = strlen(s_device_name);
    fields.name_is_complete = 1;
    fields.tx_pwr_lvl = BLE_HS_ADV_TX_PWR_LVL_AUTO;
    fields.tx_pwr_lvl_is_present = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "Failed to set adv fields: %d", rc);
        return;
    }

    struct ble_gap_adv_params adv_params = { 0 };
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;   /* undirected connectable */
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;    /* general discoverable */
    adv_params.itvl_min = BLE_GAP_ADV_ITVL_MS(100);
    adv_params.itvl_max = BLE_GAP_ADV_ITVL_MS(150);

    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER,
                           &adv_params, ble_gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "Failed to start advertising: %d", rc);
    } else {
        ESP_LOGI(TAG, "Advertising started as '%s'", s_device_name);
    }
}

/* ---------------------------------------------------------------------------
 * NimBLE host sync callback — called when host and controller sync
 * --------------------------------------------------------------------------- */

static void ble_on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    assert(rc == 0);

    start_advertising();
}

/* ---------------------------------------------------------------------------
 * NimBLE host task (runs on its own FreeRTOS task)
 * --------------------------------------------------------------------------- */

static void ble_host_task(void *param)
{
    ESP_LOGI(TAG, "NimBLE host task started");
    nimble_port_run();          /* runs until nimble_port_stop() */
    nimble_port_freertos_deinit();
}

/* ===========================================================================
 * NIF implementations
 * =========================================================================== */

/*
 * ble_nif:init/1 - Initialize the BLE stack
 *
 * Args: device_name (binary/string)
 * Returns: :ok | {:error, reason}
 */
static term nif_ble_init(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    /* Store owner PID and global context */
    s_global = ctx->global;
    s_owner_pid = ctx->process_id;

    /* Extract device name */
    if (term_is_binary(argv[0])) {
        int len = term_binary_size(argv[0]);
        if (len > (int)sizeof(s_device_name) - 1) len = sizeof(s_device_name) - 1;
        memcpy(s_device_name, term_binary_data(argv[0]), len);
        s_device_name[len] = '\0';
    }
    /* Also accept charlists */
    /* TODO: handle charlist conversion */

    ESP_LOGI(TAG, "Initializing BLE as '%s'", s_device_name);

    /* Initialize NVS (may already be initialized) */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES ||
        ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "NVS init failed: %d", ret);
        /* Return {:error, :nvs_failed} */
        term error_tuple = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(error_tuple, 0, ERROR_ATOM);
        term_put_tuple_element(error_tuple, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xA", "nvs_failed")));
        return error_tuple;
    }

    /* Initialize NimBLE */
    int rc = nimble_port_init();
    if (rc != 0) {
        ESP_LOGE(TAG, "nimble_port_init failed: %d", rc);
        term error_tuple = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(error_tuple, 0, ERROR_ATOM);
        term_put_tuple_element(error_tuple, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xB", "nimble_init")));
        return error_tuple;
    }

    /* Set device name for GAP */
    ble_svc_gap_device_name_set(s_device_name);

    /* Register GATT services */
    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_gatts_count_cfg(gatt_svcs);
    assert(rc == 0);
    rc = ble_gatts_add_svcs(gatt_svcs);
    assert(rc == 0);

    /* Set sync callback */
    ble_hs_cfg.sync_cb = ble_on_sync;

    /* Start host task */
    nimble_port_freertos_init(ble_host_task);

    ESP_LOGI(TAG, "BLE initialized successfully");
    return OK_ATOM;
}

/*
 * ble_nif:advertise/0 - Start advertising (re-advertise after stop)
 */
static term nif_ble_advertise(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    start_advertising();
    return OK_ATOM;
}

/*
 * ble_nif:notify/3 - Send a GATT notification
 *
 * Args: conn_handle (int), char_index (int), data (binary)
 * Returns: :ok | {:error, reason}
 */
static term nif_ble_notify(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (!s_connected) {
        term error_tuple = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(error_tuple, 0, ERROR_ATOM);
        term_put_tuple_element(error_tuple, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xD", "not_connected")));
        return error_tuple;
    }

    int chr_index = term_to_int(argv[1]);
    if (chr_index < 0 || chr_index >= s_chr_count) {
        chr_index = 0;
    }

    uint16_t val_handle = s_chr_val_handles[chr_index];

    if (!term_is_binary(argv[2])) {
        return ERROR_ATOM;
    }

    const char *data = term_binary_data(argv[2]);
    int len = term_binary_size(argv[2]);

    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
    if (om == NULL) {
        return ERROR_ATOM;
    }

    int rc = ble_gatts_notify_custom(s_conn_handle, val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "Notify failed: %d", rc);
        return ERROR_ATOM;
    }

    return OK_ATOM;
}

/*
 * ble_nif:add_service/2 - Placeholder (services are currently static)
 *
 * In a future version, this would dynamically build the GATT table
 * from Erlang-side service/characteristic definitions.
 */
static term nif_ble_add_service(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    /* Services are statically defined for now.
     * Dynamic service registration would require:
     * 1. Parse the Erlang term tree (UUIDs, flags)
     * 2. Build ble_gatt_svc_def structs dynamically
     * 3. Call ble_gatts_add_svcs() before host sync
     */
    ESP_LOGI(TAG, "add_service: using static service definition");
    s_chr_count = 1;  /* We have one characteristic defined statically */
    return OK_ATOM;
}

/* ===========================================================================
 * NIF registration
 * =========================================================================== */

static const struct Nif ble_init_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ble_init
};

static const struct Nif ble_advertise_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ble_advertise
};

static const struct Nif ble_notify_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ble_notify
};

static const struct Nif ble_add_service_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ble_add_service
};

void atomvm_ble_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_ble component loaded");
}

const struct Nif *atomvm_ble_nif_get_nif(const char *nifname)
{
    if (strcmp("ble_nif:init/1", nifname) == 0) {
        return &ble_init_nif;
    }
    if (strcmp("ble_nif:advertise/0", nifname) == 0) {
        return &ble_advertise_nif;
    }
    if (strcmp("ble_nif:notify/3", nifname) == 0) {
        return &ble_notify_nif;
    }
    if (strcmp("ble_nif:add_service/2", nifname) == 0) {
        return &ble_add_service_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_ble, atomvm_ble_nif_init, NULL, atomvm_ble_nif_get_nif)

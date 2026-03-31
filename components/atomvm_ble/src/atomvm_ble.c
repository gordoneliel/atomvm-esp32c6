/*
 * atomvm_ble.c - BLE peripheral NIF for AtomVM on ESP32-C6
 *
 * Provides a minimal BLE peripheral (GATT server) interface:
 *   ble_nif:init/1       - Initialize NimBLE stack (does not start host)
 *   ble_nif:add_service/2 - Register a GATT service with characteristics
 *   ble_nif:advertise/0  - Start host task (first call) and BLE advertising
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
#include <stdlib.h>
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
#include <host/ble_att.h>
#include <host/ble_hs.h>
#include <host/ble_gap.h>
#include <host/util/util.h>
#include <services/gap/ble_svc_gap.h>
#include <services/gatt/ble_svc_gatt.h>

#define TAG "atomvm_ble"
#define MAX_SERVICES 4
#define MAX_CHARACTERISTICS 8

/* ---------------------------------------------------------------------------
 * Module state
 * --------------------------------------------------------------------------- */

static GlobalContext *s_global = NULL;
static int32_t s_owner_pid = -1;          /* Erlang PID that called init/1 */
static uint16_t s_conn_handle = 0;
static bool s_connected = false;
static bool s_host_started = false;
static bool s_deinitialized = false;

static char s_device_name[32] = "atomvm";

/* Characteristic value handles (populated after service registration) */
static uint16_t s_chr_val_handles[MAX_CHARACTERISTICS];
static int s_chr_count = 0;

/* Dynamic GATT service storage — heap-allocated, must persist */
static int s_svc_count = 0;

/* Per-service: heap-allocated UUID + characteristic array + their UUIDs */
typedef struct {
    ble_uuid_any_t svc_uuid;
    ble_uuid_any_t *chr_uuids;       /* array of chr_count UUIDs */
    struct ble_gatt_chr_def *chr_defs; /* array of chr_count+1 (null terminated) */
    struct ble_gatt_svc_def svc_def[2]; /* service + terminator */
    int chr_count;
} dynamic_service_t;

static dynamic_service_t *s_services[MAX_SERVICES];

/* ---------------------------------------------------------------------------
 * Forward declarations
 * --------------------------------------------------------------------------- */

static int ble_gap_event_cb(struct ble_gap_event *event, void *arg);
static void ble_on_sync(void);
static void ble_host_task(void *param);
static void start_advertising(void);

/* ---------------------------------------------------------------------------
 * Helper: send a message to the owner Erlang process from a FreeRTOS task
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
 * Helper: parse characteristic flags from Erlang atom list
 * --------------------------------------------------------------------------- */

static const AtomStringIntPair chr_flag_table[] = {
    { ATOM_STR("\x4", "read"),         BLE_GATT_CHR_F_READ },
    { ATOM_STR("\x5", "write"),        BLE_GATT_CHR_F_WRITE },
    { ATOM_STR("\xC", "write_no_rsp"), BLE_GATT_CHR_F_WRITE_NO_RSP },
    { ATOM_STR("\x6", "notify"),       BLE_GATT_CHR_F_NOTIFY },
    { ATOM_STR("\x8", "indicate"),     BLE_GATT_CHR_F_INDICATE },
    SELECT_INT_DEFAULT(0)
};

static ble_gatt_chr_flags parse_chr_flags(GlobalContext *glb, term flags_list)
{
    ble_gatt_chr_flags flags = 0;

    term head = flags_list;
    while (term_is_nonempty_list(head)) {
        term flag = term_get_list_head(head);
        int val = interop_atom_term_select_int(chr_flag_table, flag, glb);
        flags |= (ble_gatt_chr_flags)val;
        head = term_get_list_tail(head);
    }

    return flags;
}

/* ---------------------------------------------------------------------------
 * Helper: parse a 16-byte binary into a ble_uuid_any_t (128-bit UUID)
 *         or a 2-byte binary into a 16-bit UUID
 * --------------------------------------------------------------------------- */

static bool parse_uuid(term uuid_term, ble_uuid_any_t *out)
{
    if (!term_is_binary(uuid_term)) return false;

    int len = term_binary_size(uuid_term);
    const uint8_t *data = (const uint8_t *)term_binary_data(uuid_term);

    if (len == 16) {
        out->u128.u.type = BLE_UUID_TYPE_128;
        /* NimBLE stores 128-bit UUIDs in little-endian byte order */
        for (int i = 0; i < 16; i++) {
            out->u128.value[i] = data[15 - i];
        }
        return true;
    } else if (len == 2) {
        out->u16.u.type = BLE_UUID_TYPE_16;
        out->u16.value = (uint16_t)(data[0] << 8) | data[1];
        return true;
    }

    return false;
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
        uint16_t data_len = OS_MBUF_PKTLEN(ctxt->om);
        ESP_LOGI(TAG, "GATT write on handle %d, len=%d", attr_handle, data_len);

        if (s_owner_pid < 0 || s_global == NULL) break;

        /* Reverse-lookup: attr_handle -> characteristic index */
        int chr_idx = -1;
        for (int i = 0; i < s_chr_count; i++) {
            if (s_chr_val_handles[i] == attr_handle) {
                chr_idx = i;
                break;
            }
        }
        if (chr_idx < 0) {
            ESP_LOGW(TAG, "Unknown attr_handle %d in write callback", attr_handle);
            break;
        }

        /* Flatten mbuf chain into stack buffer */
        uint8_t buf[256];
        uint16_t copy_len = data_len > sizeof(buf) ? sizeof(buf) : data_len;
        os_mbuf_copydata(ctxt->om, 0, copy_len, buf);

        /* Send {:ble_write, chr_index, data} to owner process */
        BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3) + term_binary_heap_size(copy_len), heap);
        {
            term bin = term_from_literal_binary(buf, copy_len, &heap, s_global);
            term msg = port_heap_create_tuple3(&heap,
                globalcontext_make_atom(s_global, ATOM_STR("\x9", "ble_write")),
                term_from_int(chr_idx),
                bin);
            port_send_message_from_task(s_global,
                term_from_local_process_id(s_owner_pid), msg);
        }
        END_WITH_STACK_HEAP(heap, s_global);
        break;
    }

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }

    return 0;
}

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

            /* Request faster connection parameters for higher throughput */
            struct ble_gap_upd_params conn_params = {
                .itvl_min = 24,             /* 30ms  (24 * 1.25ms) */
                .itvl_max = 40,             /* 50ms  (40 * 1.25ms) */
                .latency = 0,
                .supervision_timeout = 600  /* 6000ms (600 * 10ms) */
            };
            ble_gap_update_params(s_conn_handle, &conn_params);
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

    case BLE_GAP_EVENT_SUBSCRIBE: {
        uint16_t attr_handle = event->subscribe.attr_handle;
        int chr_idx = -1;
        for (int i = 0; i < s_chr_count; i++) {
            if (s_chr_val_handles[i] == attr_handle) {
                chr_idx = i;
                break;
            }
        }
        ESP_LOGI(TAG, "Subscribe event: cur_notify=%d, attr_handle=%d, chr_idx=%d",
                 event->subscribe.cur_notify, attr_handle, chr_idx);

        if (chr_idx >= 0) {
            if (event->subscribe.cur_notify) {
                send_event_to_owner_2(
                    make_atom(s_global, ATOM_STR("\xE", "ble_subscribed")),
                    term_from_int(chr_idx));
            } else {
                send_event_to_owner_2(
                    make_atom(s_global, ATOM_STR("\x10", "ble_unsubscribed")),
                    term_from_int(chr_idx));
            }
        }
        break;
    }

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU negotiated: %d", event->mtu.value);
        send_event_to_owner_2(
            make_atom(s_global, ATOM_STR("\x7", "ble_mtu")),
            term_from_int(event->mtu.value));
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
    if (s_deinitialized) return;
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
 * Initializes NimBLE and GAP/GATT core services but does NOT start the
 * host task. Call add_service/2 to register services, then advertise/0
 * to start the host and begin advertising.
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

    /* Initialize GAP and GATT core services */
    ble_svc_gap_init();
    ble_svc_gatt_init();

    /* Set device name for GAP (must be after ble_svc_gap_init) */
    ble_svc_gap_device_name_set(s_device_name);

    /* Reset dynamic service state */
    s_svc_count = 0;
    s_chr_count = 0;
    s_host_started = false;
    s_deinitialized = false;

    ESP_LOGI(TAG, "BLE initialized (call add_service then advertise)");
    return OK_ATOM;
}

/*
 * ble_nif:add_service/2 - Register a GATT service dynamically
 *
 * Args:
 *   service_uuid (binary) - 16-byte (128-bit) or 2-byte (16-bit) UUID
 *   characteristics (list) - [{:characteristic, uuid_binary, [flag_atoms]}, ...]
 *
 * Must be called after init/1 and before advertise/0.
 * Returns: :ok | {:error, reason}
 */
static term nif_ble_add_service(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    GlobalContext *glb = ctx->global;

    if (s_host_started) {
        ESP_LOGE(TAG, "add_service: host already started");
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\xF", "already_started")));
        return t;
    }

    if (s_svc_count >= MAX_SERVICES) {
        ESP_LOGE(TAG, "add_service: max services reached");
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x8", "max_svcs")));
        return t;
    }

    /* Parse service UUID */
    ble_uuid_any_t svc_uuid;
    if (!parse_uuid(argv[0], &svc_uuid)) {
        ESP_LOGE(TAG, "add_service: invalid service UUID");
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\xB", "bad_svc_uuid")));
        return t;
    }

    /* Count characteristics */
    int chr_count = 0;
    term chr_list = argv[1];
    term tmp = chr_list;
    while (term_is_nonempty_list(tmp)) {
        chr_count++;
        tmp = term_get_list_tail(tmp);
    }

    if (s_chr_count + chr_count > MAX_CHARACTERISTICS) {
        ESP_LOGE(TAG, "add_service: too many characteristics (%d + %d > %d)",
                 s_chr_count, chr_count, MAX_CHARACTERISTICS);
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x8", "max_chrs")));
        return t;
    }

    /* Allocate persistent storage for this service */
    dynamic_service_t *svc = calloc(1, sizeof(dynamic_service_t));
    if (!svc) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    svc->chr_count = chr_count;
    svc->svc_uuid = svc_uuid;

    /* Allocate characteristic UUIDs and definitions (chr_count + 1 for terminator) */
    svc->chr_uuids = calloc(chr_count, sizeof(ble_uuid_any_t));
    svc->chr_defs = calloc(chr_count + 1, sizeof(struct ble_gatt_chr_def));
    if (!svc->chr_uuids || !svc->chr_defs) {
        free(svc->chr_uuids);
        free(svc->chr_defs);
        free(svc);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    /* Parse each characteristic: {:characteristic, uuid_binary, [flags]} */
    tmp = chr_list;
    for (int i = 0; i < chr_count; i++) {
        term chr_tuple = term_get_list_head(tmp);
        tmp = term_get_list_tail(tmp);

        if (!term_is_tuple(chr_tuple) || term_get_tuple_arity(chr_tuple) != 3) {
            ESP_LOGE(TAG, "add_service: bad characteristic tuple at index %d", i);
            free(svc->chr_uuids);
            free(svc->chr_defs);
            free(svc);
            term t = term_alloc_tuple(2, &ctx->heap);
            term_put_tuple_element(t, 0, ERROR_ATOM);
            term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x7", "bad_chr")));
            return t;
        }

        /* argv[1] of tuple = UUID binary */
        term chr_uuid_term = term_get_tuple_element(chr_tuple, 1);
        if (!parse_uuid(chr_uuid_term, &svc->chr_uuids[i])) {
            ESP_LOGE(TAG, "add_service: bad characteristic UUID at index %d", i);
            free(svc->chr_uuids);
            free(svc->chr_defs);
            free(svc);
            term t = term_alloc_tuple(2, &ctx->heap);
            term_put_tuple_element(t, 0, ERROR_ATOM);
            term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\xB", "bad_chr_uuid")));
            return t;
        }

        /* argv[2] of tuple = flags list */
        term flags_term = term_get_tuple_element(chr_tuple, 2);
        ble_gatt_chr_flags flags = parse_chr_flags(glb, flags_term);

        int handle_idx = s_chr_count + i;
        svc->chr_defs[i].uuid = &svc->chr_uuids[i].u;
        svc->chr_defs[i].access_cb = gatt_chr_access_cb;
        svc->chr_defs[i].val_handle = &s_chr_val_handles[handle_idx];
        svc->chr_defs[i].flags = flags;

        ESP_LOGI(TAG, "  chr[%d]: flags=0x%04x, handle_idx=%d",
                 i, flags, handle_idx);
    }
    /* Terminator already zero from calloc */

    /* Build service definition */
    svc->svc_def[0].type = BLE_GATT_SVC_TYPE_PRIMARY;
    svc->svc_def[0].uuid = &svc->svc_uuid.u;
    svc->svc_def[0].characteristics = svc->chr_defs;
    /* svc_def[1] is terminator (zero from calloc) */

    /* Register with NimBLE */
    int rc = ble_gatts_count_cfg(svc->svc_def);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_cfg failed: %d", rc);
        free(svc->chr_uuids);
        free(svc->chr_defs);
        free(svc);
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x9", "count_cfg")));
        return t;
    }

    rc = ble_gatts_add_svcs(svc->svc_def);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed: %d", rc);
        free(svc->chr_uuids);
        free(svc->chr_defs);
        free(svc);
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, globalcontext_make_atom(glb, ATOM_STR("\x8", "add_svcs")));
        return t;
    }

    s_services[s_svc_count] = svc;
    s_svc_count++;
    s_chr_count += chr_count;

    ESP_LOGI(TAG, "Service added: %d characteristics (total: %d chrs across %d svcs)",
             chr_count, s_chr_count, s_svc_count);
    return OK_ATOM;
}

/*
 * ble_nif:advertise/0 - Start host task (first call) and BLE advertising
 *
 * On first call, starts the NimBLE host task which triggers ble_on_sync
 * and begins advertising. Subsequent calls restart advertising.
 */
static term nif_ble_advertise(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    if (s_deinitialized) {
        ESP_LOGW(TAG, "BLE deinitialized, ignoring advertise");
        return OK_ATOM;
    }

    if (!s_host_started) {
        /* Set sync callback and preferred MTU before starting host */
        ble_hs_cfg.sync_cb = ble_on_sync;
        ble_att_set_preferred_mtu(512);
        nimble_port_freertos_init(ble_host_task);
        s_host_started = true;
        ESP_LOGI(TAG, "Host task started (preferred MTU=512), will advertise on sync");
    } else {
        start_advertising();
    }

    return OK_ATOM;
}

/*
 * ble_nif:deinit/0 - Stop BLE and free resources
 */
static term nif_ble_deinit(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    if (s_host_started) {
        ESP_LOGI(TAG, "Stopping BLE to free RAM");
        int rc = nimble_port_stop();
        if (rc == 0) {
            nimble_port_deinit();
            s_host_started = false;
            s_connected = false;
            s_deinitialized = true;
            s_svc_count = 0;
            s_chr_count = 0;
            ESP_LOGI(TAG, "BLE deinitialized");
        } else {
            ESP_LOGE(TAG, "nimble_port_stop failed: %d", rc);
        }
    }

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

static const struct Nif ble_deinit_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ble_deinit
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
    if (strcmp("ble_nif:deinit/0", nifname) == 0) {
        return &ble_deinit_nif;
    }
    if (strcmp("ble_nif:add_service/2", nifname) == 0) {
        return &ble_add_service_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_ble, atomvm_ble_nif_init, NULL, atomvm_ble_nif_get_nif)

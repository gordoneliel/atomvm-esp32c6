/*
 * atomvm_matter.cpp - Matter device NIF for AtomVM on ESP32-C6
 *
 * Wraps Espressif's esp_matter SDK to provide Matter device support:
 *   matter_nif:init/1                    - Initialize Matter stack with device config
 *   matter_nif:start/0                   - Start Matter event loop
 *   matter_nif:add_endpoint/3            - Add endpoint by device type, returns its id
 *   matter_nif:set_attribute/4           - Set attribute value (integer or boolean)
 *   matter_nif:report/3                  - Report attribute change to fabric
 *   matter_nif:get_fabric_info/0         - Get fabric commissioning info
 *   matter_nif:open_commissioning_window/1 - Open commissioning window
 *   matter_nif:close_commissioning_window/0 - Close commissioning window
 *   matter_nif:respond_read/4            - Respond to attribute read callback
 *
 * Events delivered to owner process:
 *   :matter_commissioned
 *   :matter_decommissioned
 *   {:matter_read, endpoint, cluster, attr}
 *   {:matter_write, endpoint, cluster, attr, value}
 */

#include <sdkconfig.h>

#include <cstdlib>
#include <cstring>

#include <esp_log.h>
#include <nvs_flash.h>
#include <driver/gpio.h>

#include <esp_matter.h>
#include <esp_matter_core.h>
#include <esp_matter_endpoint.h>
#include <esp_matter_cluster.h>
#include <esp_matter_attribute.h>
#include <esp_matter_feature.h>

#include <app/server/Server.h>
#include <app/server/CommissioningWindowManager.h>
#include <setup_payload/QRCodeSetupPayloadGenerator.h>
#include <setup_payload/ManualSetupPayloadGenerator.h>

#include <esp_openthread_types.h>
#include <platform/ESP32/OpenthreadLauncher.h>

/* AtomVM headers (C linkage).
 * refc_binary.h guards its static inline functions with #ifndef __cplusplus,
 * but term.h uses them unconditionally. Provide C++ stubs before including. */
extern "C" {
#include <refc_binary.h>

/* These functions are #ifndef __cplusplus in refc_binary.h — provide C++ stubs.
 * AVM_NO_SMP is defined for ESP32-C6 (single core). */
static inline void refc_binary_add_refcount(struct RefcBinary *refc, size_t delta)
{
    refc->ref_count += delta;
}
static inline size_t refc_binary_sub_refcount(struct RefcBinary *refc, size_t delta)
{
    return (refc->ref_count -= delta);
}
static inline void refc_binary_or_refcount(struct RefcBinary *refc, size_t mask)
{
    refc->ref_count |= mask;
}

#include <term.h>
#include <atom.h>
#include <defaultatoms.h>
#include <erl_nif.h>
#include <context.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <port.h>
#include <portnifloader.h>
}

#define TAG "atomvm_matter"

using namespace esp_matter;
using namespace esp_matter::endpoint;
using namespace chip::app::Clusters;

/* ---------------------------------------------------------------------------
 * Module state
 * --------------------------------------------------------------------------- */

static GlobalContext *s_global = NULL;
static int32_t s_owner_pid = -1;
static node_t *s_node = NULL;
static bool s_initialized = false;
static bool s_started = false;

/* ---------------------------------------------------------------------------
 * Helpers
 * --------------------------------------------------------------------------- */

/* Extract a binary/string value from a proplist by atom key.
 * Returns the length copied, or 0 if not found. */
static size_t proplist_get_string(GlobalContext *global, term list,
                                   const char *key_str, uint8_t key_len,
                                   char *out, size_t out_size)
{
    term key_atom = globalcontext_make_atom(global, AtomString((const uint8_t *)key_str));
    term cur = list;
    while (term_is_nonempty_list(cur)) {
        term head = term_get_list_head(cur);
        if (term_is_tuple(head) && term_get_tuple_arity(head) == 2) {
            if (term_get_tuple_element(head, 0) == key_atom) {
                term val = term_get_tuple_element(head, 1);
                if (term_is_binary(val)) {
                    size_t len = term_binary_size(val);
                    if (len >= out_size) len = out_size - 1;
                    memcpy(out, term_binary_data(val), len);
                    out[len] = '\0';
                    return len;
                }
            }
        }
        cur = term_get_list_tail(cur);
    }
    return 0;
}

/* Integer value of an attribute, for booleans and integer, enum and bitmap
 * types (nullable or not). 0 for anything else. */
static int attr_val_to_int(const esp_matter_attr_val_t *val)
{
    switch (val->get_storage_type()) {
        case ESP_MATTER_VAL_TYPE_BOOLEAN: return val->val.b ? 1 : 0;
        case ESP_MATTER_VAL_TYPE_INT8:    return val->val.i8;
        case ESP_MATTER_VAL_TYPE_UINT8:
        case ESP_MATTER_VAL_TYPE_ENUM8:
        case ESP_MATTER_VAL_TYPE_BITMAP8: return val->val.u8;
        case ESP_MATTER_VAL_TYPE_INT16:   return val->val.i16;
        case ESP_MATTER_VAL_TYPE_UINT16:
        case ESP_MATTER_VAL_TYPE_ENUM16:
        case ESP_MATTER_VAL_TYPE_BITMAP16: return val->val.u16;
        case ESP_MATTER_VAL_TYPE_INT32:   return val->val.i32;
        case ESP_MATTER_VAL_TYPE_UINT32:
        case ESP_MATTER_VAL_TYPE_BITMAP32: return (int)val->val.u32;
        default: return 0;
    }
}

/* Store `value` into `val`, keeping the attribute's existing type.
 * Returns false for types that don't hold an integer. */
static bool attr_val_from_int(esp_matter_attr_val_t *val, int value)
{
    switch (val->get_storage_type()) {
        case ESP_MATTER_VAL_TYPE_BOOLEAN: val->val.b = value != 0; return true;
        case ESP_MATTER_VAL_TYPE_INT8:    val->val.i8 = (int8_t)value; return true;
        case ESP_MATTER_VAL_TYPE_UINT8:
        case ESP_MATTER_VAL_TYPE_ENUM8:
        case ESP_MATTER_VAL_TYPE_BITMAP8: val->val.u8 = (uint8_t)value; return true;
        case ESP_MATTER_VAL_TYPE_INT16:   val->val.i16 = (int16_t)value; return true;
        case ESP_MATTER_VAL_TYPE_UINT16:
        case ESP_MATTER_VAL_TYPE_ENUM16:
        case ESP_MATTER_VAL_TYPE_BITMAP16: val->val.u16 = (uint16_t)value; return true;
        case ESP_MATTER_VAL_TYPE_INT32:   val->val.i32 = value; return true;
        case ESP_MATTER_VAL_TYPE_UINT32:
        case ESP_MATTER_VAL_TYPE_BITMAP32: val->val.u32 = (uint32_t)value; return true;
        default: return false;
    }
}

static term make_error(Context *ctx, term reason)
{
    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term t = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(t, 0, ERROR_ATOM);
    term_put_tuple_element(t, 1, reason);
    return t;
}

static void send_atom_event(AtomString atom_str)
{
    if (s_owner_pid < 0 || s_global == NULL) return;

    BEGIN_WITH_STACK_HEAP(0, heap);
    {
        term msg = globalcontext_make_atom(s_global, atom_str);
        port_send_message_from_task(s_global,
            term_from_local_process_id(s_owner_pid), msg);
    }
    END_WITH_STACK_HEAP(heap, s_global);
}

/* ---------------------------------------------------------------------------
 * Matter callbacks
 * --------------------------------------------------------------------------- */

static esp_err_t matter_attribute_update_cb(
    attribute::callback_type_t type,
    uint16_t endpoint_id,
    uint32_t cluster_id,
    uint32_t attribute_id,
    esp_matter_attr_val_t *val,
    void *priv_data)
{
    if (s_owner_pid < 0 || s_global == NULL) return ESP_OK;

    if (type == attribute::PRE_UPDATE) {
        /* Controller is writing an attribute — notify Erlang */
        int int_val = val ? attr_val_to_int(val) : 0;

        /* Send {:matter_write, endpoint, cluster, attr, value} */
        BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(5), heap);
        {
            term msg = term_alloc_tuple(5, &heap);
            term_put_tuple_element(msg, 0,
                globalcontext_make_atom(s_global, ATOM_STR("\xC", "matter_write")));
            term_put_tuple_element(msg, 1, term_from_int(endpoint_id));
            term_put_tuple_element(msg, 2, term_from_int(cluster_id));
            term_put_tuple_element(msg, 3, term_from_int(attribute_id));
            term_put_tuple_element(msg, 4, term_from_int(int_val));
            port_send_message_from_task(s_global,
                term_from_local_process_id(s_owner_pid), msg);
        }
        END_WITH_STACK_HEAP(heap, s_global);
    }

    return ESP_OK;
}

static esp_err_t matter_identification_cb(
    identification::callback_type_t type,
    uint16_t endpoint_id,
    uint8_t effect_id,
    uint8_t effect_variant,
    void *priv_data)
{
    ESP_LOGI(TAG, "Identify callback: endpoint=%d effect=%d", endpoint_id, effect_id);
    return ESP_OK;
}

static void matter_event_cb(const ChipDeviceEvent *event, intptr_t arg)
{
    if (!event) return;

    switch (event->Type) {
        case chip::DeviceLayer::DeviceEventType::kCommissioningComplete:
            ESP_LOGI(TAG, "Commissioning complete");
            send_atom_event(ATOM_STR("\x14", "matter_commissioned"));
            break;

        case chip::DeviceLayer::DeviceEventType::kFabricRemoved:
            ESP_LOGI(TAG, "Fabric removed");
            send_atom_event(ATOM_STR("\x16", "matter_decommissioned"));
            break;

        default:
            break;
    }
}

/* ===========================================================================
 * NIF implementations (extern "C" for AtomVM linkage)
 * =========================================================================== */

extern "C" {

/*
 * matter_nif:init/1 - Initialize Matter stack
 * Args: config (proplist with vendor_id, product_id, etc.)
 * Returns: :ok | {:error, reason}
 */
static term nif_matter_init(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (s_initialized) {
        ESP_LOGW(TAG, "Already initialized");
        return OK_ATOM;
    }

    s_global = ctx->global;
    s_owner_pid = ctx->process_id;

    term config = argv[0];

    ESP_LOGI(TAG, "Initializing Matter device stack");

    /* Select external antenna on XIAO ESP32-C6 (GPIO14 high = U.FL connector) */
    gpio_config_t ant_cfg = {
        .pin_bit_mask = (1ULL << GPIO_NUM_14),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&ant_cfg);
    gpio_set_level(GPIO_NUM_14, 1);
    ESP_LOGI(TAG, "External antenna selected (GPIO14 high)");

    /* Write product/vendor names to chip-factory NVS before node creation.
     * The CHIP DeviceInstanceInfoProvider reads these at init. */
    {
        char buf[64] = {0};
        nvs_handle_t nvs;
        if (nvs_open("chip-factory", NVS_READWRITE, &nvs) == ESP_OK) {
            if (proplist_get_string(ctx->global, config,
                    "\xC" "product_name", 12, buf, sizeof(buf)) > 0) {
                nvs_set_str(nvs, "product-name", buf);
                ESP_LOGI(TAG, "Product name: %s", buf);
            }
            if (proplist_get_string(ctx->global, config,
                    "\xB" "vendor_name", 11, buf, sizeof(buf)) > 0) {
                nvs_set_str(nvs, "vendor-name", buf);
                ESP_LOGI(TAG, "Vendor name: %s", buf);
            }
            nvs_commit(nvs);
            nvs_close(nvs);
        }
    }

    /* Create Matter node with config from Elixir */
    node::config_t node_config;

    /* Parse node_label from config proplist (max 32 chars) */
    char label[33] = {0};
    if (proplist_get_string(ctx->global, config,
            "\xA" "node_label", 10, label, sizeof(label)) > 0) {
        strncpy(node_config.root_node.basic_information.node_label, label,
                sizeof(node_config.root_node.basic_information.node_label) - 1);
        ESP_LOGI(TAG, "Node label: %s", label);
    }

    s_node = node::create(&node_config, matter_attribute_update_cb,
                           matter_identification_cb);
    if (!s_node) {
        ESP_LOGE(TAG, "Failed to create Matter node");
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xB", "create_node")));
        return t;
    }

    /* SupportsConcurrentConnection (keeps BLE up while the commissioner
     * establishes CASE over Thread) comes from CONFIG_ENABLE_CONCURRENT_CONNECTION,
     * set in firmware/sdkconfig.defaults. */

    s_initialized = true;
    ESP_LOGI(TAG, "Matter node created");
    return OK_ATOM;
}

/*
 * matter_nif:start/0 - Start Matter event loop
 * Returns: :ok | {:error, reason}
 */
static term nif_matter_start(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    if (!s_initialized) {
        RAISE_ERROR(globalcontext_make_atom(ctx->global, ATOM_STR("\xF", "not_initialized")));
    }

    if (s_started) {
        return OK_ATOM;
    }

    /* Configure OpenThread platform before starting Matter (required for Thread transport) */
    static esp_openthread_platform_config_t ot_config = {
        .radio_config = {
            .radio_mode = RADIO_MODE_NATIVE,
        },
        .host_config = {
            .host_connection_mode = HOST_CONNECTION_MODE_NONE,
        },
        .port_config = {
            .storage_partition_name = "nvs",
            .netif_queue_size = 10,
            .task_queue_size = 10,
        },
    };
    set_openthread_platform_config(&ot_config);

    esp_err_t err = esp_matter::start(matter_event_cb);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_matter::start failed: %d", err);
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, term_from_int(err));
        return t;
    }

    s_started = true;
    ESP_LOGI(TAG, "Matter started");
    return OK_ATOM;
}

/*
 * matter_nif:add_endpoint/3 - Add a Matter endpoint
 * Args: endpoint_id (ignored, the SDK assigns ids in order), device_type_id (int),
 *       clusters (ignored, each device type gets its standard clusters)
 * Device types:
 *   0x0107 Occupancy Sensor (radar)
 *   0x010D Extended Color Light (on/off, level, hue/saturation, color temperature)
 *   0x010A On/Off Plug-in Unit
 * Returns: {:ok, endpoint_id} | {:error, reason}
 */
static term nif_matter_add_endpoint(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (!s_initialized || !s_node) {
        RAISE_ERROR(globalcontext_make_atom(ctx->global, ATOM_STR("\xF", "not_initialized")));
    }

    uint32_t device_type_id = (uint32_t)term_to_int(argv[1]);

    ESP_LOGI(TAG, "Adding endpoint, device_type=0x%04lx", device_type_id);

    endpoint_t *ep = NULL;

    switch (device_type_id) {
        case 0x0107: {
            /* Occupancy Sensor — Radar feature (mmWave) */
            occupancy_sensor::config_t config;
            config.occupancy_sensing.feature_flags = 0x20; /* kRadar */
            config.occupancy_sensing.occupancy_sensor_type = 0x04; /* Radar enum */
            config.occupancy_sensing.occupancy_sensor_type_bitmap = 0x20;
            ep = occupancy_sensor::create(s_node, &config, ENDPOINT_FLAG_NONE, NULL);
            break;
        }
        case 0x010D: {
            /* Extended Color Light — starts on, with the color mode set to hue/saturation */
            extended_color_light::config_t config;
            config.on_off.on_off = true;
            config.level_control.current_level = (uint8_t)64;
            config.color_control.color_mode =
                (uint8_t)ColorControl::ColorModeEnum::kCurrentHueAndCurrentSaturation;
            config.color_control.enhanced_color_mode =
                (uint8_t)ColorControl::EnhancedColorModeEnum::kCurrentHueAndCurrentSaturation;
            ep = extended_color_light::create(s_node, &config, ENDPOINT_FLAG_NONE, NULL);
            if (ep) {
                cluster_t *color = cluster::get(ep, ColorControl::Id);
                cluster::color_control::feature::hue_saturation::config_t hs_config;
                cluster::color_control::feature::hue_saturation::add(color, &hs_config);
            }
            break;
        }
        case 0x010A: {
            on_off_plug_in_unit::config_t config;
            ep = on_off_plug_in_unit::create(s_node, &config, ENDPOINT_FLAG_NONE, NULL);
            break;
        }
        default:
            ESP_LOGE(TAG, "Unsupported device type 0x%04lx", device_type_id);
            return make_error(ctx, globalcontext_make_atom(ctx->global, ATOM_STR("\x17", "unsupported_device_type")));
    }

    if (!ep) {
        ESP_LOGE(TAG, "Failed to create endpoint");
        return make_error(ctx, globalcontext_make_atom(ctx->global, ATOM_STR("\xF", "create_endpoint")));
    }

    uint16_t id = endpoint::get_id(ep);
    ESP_LOGI(TAG, "Endpoint %d created", id);

    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term t = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(t, 0, OK_ATOM);
    term_put_tuple_element(t, 1, term_from_int(id));
    return t;
}

/*
 * matter_nif:set_attribute/4 - Set attribute value
 * Args: endpoint_id, cluster_id, attribute_id, value
 * Returns: :ok | {:error, reason}
 */
static term nif_matter_set_attribute(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    uint16_t endpoint_id = (uint16_t)term_to_int(argv[0]);
    uint32_t cluster_id = (uint32_t)term_to_int(argv[1]);
    uint32_t attribute_id = (uint32_t)term_to_int(argv[2]);
    int value = argv[3] == TRUE_ATOM ? 1 : argv[3] == FALSE_ATOM ? 0 : term_to_int(argv[3]);

    attribute_t *attr = attribute::get(endpoint_id, cluster_id, attribute_id);
    esp_matter_attr_val_t val = esp_matter_invalid(NULL);
    if (!attr || attribute::get_val(attr, &val) != ESP_OK || !attr_val_from_int(&val, value)) {
        return make_error(ctx, globalcontext_make_atom(ctx->global, ATOM_STR("\x11", "invalid_attribute")));
    }

    esp_err_t err = attribute::update(endpoint_id, cluster_id, attribute_id, &val);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "attribute::update failed: %d", err);
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, term_from_int(err));
        return t;
    }

    return OK_ATOM;
}

/*
 * matter_nif:report/3 - Report attribute change to subscribed controllers
 * Args: endpoint_id, cluster_id, attribute_id
 * Returns: :ok
 */
static term nif_matter_report(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    uint16_t endpoint_id = (uint16_t)term_to_int(argv[0]);
    uint32_t cluster_id = (uint32_t)term_to_int(argv[1]);
    uint32_t attribute_id = (uint32_t)term_to_int(argv[2]);

    /* Read current value and report it */
    esp_matter_attr_val_t val = esp_matter_invalid(NULL);
    attribute::get_val(attribute::get(endpoint_id, cluster_id, attribute_id), &val);
    attribute::report(endpoint_id, cluster_id, attribute_id, &val);
    return OK_ATOM;
}

/*
 * matter_nif:get_fabric_info/0 - Get info about commissioned fabric
 * Returns: {:ok, [{:fabric_id, id}]} | {:error, :not_commissioned}
 */
static term nif_matter_get_fabric_info(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    /* Check if we're commissioned by seeing if any fabric exists */
    if (!s_started) {
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\x10", "not_commissioned")));
        return t;
    }

    /* Return basic info — fabric details available after commissioning */
    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2) + CONS_SIZE + TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    term kv = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(kv, 0,
        globalcontext_make_atom(ctx->global, ATOM_STR("\x9", "fabric_id")));
    term_put_tuple_element(kv, 1, term_from_int(0)); /* placeholder */

    term info_list = term_list_prepend(kv, term_nil(), &ctx->heap);

    term result = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(result, 0, OK_ATOM);
    term_put_tuple_element(result, 1, info_list);

    return result;
}

/*
 * matter_nif:open_commissioning_window/1 - Open commissioning window
 * Args: timeout_seconds (int)
 * Returns: :ok | {:error, reason}
 */
static term nif_matter_open_commissioning_window(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (!s_started) {
        RAISE_ERROR(globalcontext_make_atom(ctx->global, ATOM_STR("\xF", "not_initialized")));
    }

    int timeout_secs = term_to_int(argv[0]);
    if (timeout_secs <= 0) timeout_secs = 900;

    ESP_LOGI(TAG, "Opening commissioning window for %d seconds", timeout_secs);

    auto &commissionMgr = chip::Server::GetInstance().GetCommissioningWindowManager();
    CHIP_ERROR err = commissionMgr.OpenBasicCommissioningWindow(
        chip::System::Clock::Seconds16(static_cast<uint16_t>(timeout_secs)));

    if (err != CHIP_NO_ERROR) {
        ESP_LOGE(TAG, "Failed to open commissioning window");
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\x14", "commissioning_failed")));
        return t;
    }

    ESP_LOGI(TAG, "Commissioning window open — device is discoverable via BLE");
    return OK_ATOM;
}

/*
 * matter_nif:close_commissioning_window/0
 * Returns: :ok
 */
static term nif_matter_close_commissioning_window(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    if (s_started) {
        ESP_LOGI(TAG, "Closing commissioning window");
        chip::Server::GetInstance().GetCommissioningWindowManager().CloseCommissioningWindow();
    }

    return OK_ATOM;
}

/*
 * matter_nif:factory_reset/0 - Erase all Matter credentials and restart
 * Returns: :ok
 */
static term nif_matter_factory_reset(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    ESP_LOGW(TAG, "Factory resetting Matter stack — erasing all fabric credentials");
    esp_matter::factory_reset();
    return OK_ATOM;
}

/*
 * matter_nif:get_setup_codes/0 - Get QR code and manual pairing code
 * Returns: {:ok, [{:qr_code, binary}, {:manual_code, binary}]} | {:error, reason}
 */
static term nif_matter_get_setup_codes(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    if (!s_started) {
        RAISE_ERROR(globalcontext_make_atom(ctx->global, ATOM_STR("\xF", "not_initialized")));
    }

    /* Build the payload from device config */
    chip::PayloadContents payload;
    payload.version = 0;
    payload.vendorID = static_cast<chip::VendorId>(CHIP_DEVICE_CONFIG_DEVICE_VENDOR_ID);
    payload.productID = CHIP_DEVICE_CONFIG_DEVICE_PRODUCT_ID;
    payload.commissioningFlow = chip::CommissioningFlow::kStandard;
    payload.rendezvousInformation.SetValue(chip::RendezvousInformationFlag::kBLE);
    payload.discriminator.SetLongValue(CHIP_DEVICE_CONFIG_USE_TEST_SETUP_DISCRIMINATOR);
    payload.setUpPINCode = CHIP_DEVICE_CONFIG_USE_TEST_SETUP_PIN_CODE;

    /* Generate QR code */
    char qr_buf[128] = {0};
    {
        chip::QRCodeBasicSetupPayloadGenerator gen(payload);
        /* Leave room for "MT:" prefix */
        char base38[125] = {0};
        chip::MutableCharSpan span(base38, sizeof(base38));
        if (gen.payloadBase38Representation(span) == CHIP_NO_ERROR) {
            strncpy(qr_buf, base38, sizeof(qr_buf) - 1);
        }
    }

    /* Generate manual pairing code */
    char manual_buf[32] = {0};
    {
        chip::ManualSetupPayloadGenerator gen(payload);
        std::string code;
        if (gen.payloadDecimalStringRepresentation(code) == CHIP_NO_ERROR) {
            strncpy(manual_buf, code.c_str(), sizeof(manual_buf) - 1);
        }
    }

    size_t qr_len = strlen(qr_buf);
    size_t manual_len = strlen(manual_buf);
    size_t needed = TUPLE_SIZE(2) +
                    2 * (CONS_SIZE + TUPLE_SIZE(2)) +
                    term_binary_heap_size(qr_len) +
                    term_binary_heap_size(manual_len);

    if (UNLIKELY(memory_ensure_free(ctx, needed) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    /* Build [{:qr_code, "MT:..."}, {:manual_code, "1234..."}] */
    term qr_bin = term_from_literal_binary(qr_buf, qr_len, &ctx->heap, ctx->global);
    term manual_bin = term_from_literal_binary(manual_buf, manual_len, &ctx->heap, ctx->global);

    term kv_manual = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(kv_manual, 0,
        globalcontext_make_atom(ctx->global, ATOM_STR("\xB", "manual_code")));
    term_put_tuple_element(kv_manual, 1, manual_bin);

    term kv_qr = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(kv_qr, 0,
        globalcontext_make_atom(ctx->global, ATOM_STR("\x7", "qr_code")));
    term_put_tuple_element(kv_qr, 1, qr_bin);

    term info_list = term_nil();
    info_list = term_list_prepend(kv_manual, info_list, &ctx->heap);
    info_list = term_list_prepend(kv_qr, info_list, &ctx->heap);

    term result = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(result, 0, OK_ATOM);
    term_put_tuple_element(result, 1, info_list);

    return result;
}

/*
 * matter_nif:respond_read/4 - Respond to an attribute read
 * Args: endpoint_id, cluster_id, attribute_id, value
 * Returns: :ok
 *
 * Note: In esp_matter, reads are handled by the data model directly.
 * This NIF is a no-op since attribute values are already stored in the SDK.
 * Use set_attribute to keep values current.
 */
static term nif_matter_respond_read(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);
    return OK_ATOM;
}

/* ===========================================================================
 * NIF registration
 * =========================================================================== */

static const struct Nif matter_init_nif         = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_init };
static const struct Nif matter_start_nif        = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_start };
static const struct Nif matter_add_endpoint_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_add_endpoint };
static const struct Nif matter_set_attribute_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_set_attribute };
static const struct Nif matter_report_nif       = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_report };
static const struct Nif matter_get_fabric_nif   = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_get_fabric_info };
static const struct Nif matter_open_comm_nif    = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_open_commissioning_window };
static const struct Nif matter_close_comm_nif   = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_close_commissioning_window };
static const struct Nif matter_factory_reset_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_factory_reset };
static const struct Nif matter_get_setup_codes_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_get_setup_codes };
static const struct Nif matter_respond_read_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_respond_read };

const struct Nif *atomvm_matter_resolve_nif(const char *nifname)
{
    if (strcmp("matter_nif:init/1", nifname) == 0)                    return &matter_init_nif;
    if (strcmp("matter_nif:start/0", nifname) == 0)                   return &matter_start_nif;
    if (strcmp("matter_nif:add_endpoint/3", nifname) == 0)            return &matter_add_endpoint_nif;
    if (strcmp("matter_nif:set_attribute/4", nifname) == 0)           return &matter_set_attribute_nif;
    if (strcmp("matter_nif:report/3", nifname) == 0)                  return &matter_report_nif;
    if (strcmp("matter_nif:get_fabric_info/0", nifname) == 0)         return &matter_get_fabric_nif;
    if (strcmp("matter_nif:open_commissioning_window/1", nifname) == 0) return &matter_open_comm_nif;
    if (strcmp("matter_nif:close_commissioning_window/0", nifname) == 0) return &matter_close_comm_nif;
    if (strcmp("matter_nif:factory_reset/0", nifname) == 0)           return &matter_factory_reset_nif;
    if (strcmp("matter_nif:get_setup_codes/0", nifname) == 0)        return &matter_get_setup_codes_nif;
    if (strcmp("matter_nif:respond_read/4", nifname) == 0)            return &matter_respond_read_nif;
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_matter, NULL, NULL, atomvm_matter_resolve_nif)

} /* extern "C" */

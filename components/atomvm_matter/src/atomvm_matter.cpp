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
 *   matter_nif:commissioned/0            - Whether the device is on any fabric
 *   matter_nif:thread_scan/0             - Scan for Thread networks in range
 *   matter_nif:set_antenna/1             - Select the XIAO ESP32-C6 antenna
 *   matter_nif:get_attribute/3           - Read an attribute's value
 *   matter_nif:thread_status/0           - Thread role and neighbor count
 *   matter_nif:open_commissioning_window/1 - Open commissioning window
 *   matter_nif:close_commissioning_window/0 - Close commissioning window
 *   matter_nif:respond_read/4            - Respond to attribute read callback
 *
 * Events delivered to owner process:
 *   :matter_commissioned
 *   :matter_decommissioned
 *   {:matter_read, endpoint, cluster, attr}
 *   {:matter_write, endpoint, cluster, attr, value}
 *   {:matter_identify, endpoint, :start | :stop | :effect, effect_id}
 *   {:thread_network, name, ext_pan_id, pan_id, channel, rssi}, then
 *   :thread_scan_done (after matter_nif:thread_scan/0)
 */

#include <sdkconfig.h>

#include <cstdlib>
#include <cstring>

#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <nvs_flash.h>
#include <driver/gpio.h>

#include <esp_matter.h>
#include <esp_matter_core.h>
#include <esp_matter_endpoint.h>
#include <esp_matter_cluster.h>
#include <esp_matter_attribute.h>
#include <esp_matter_feature.h>

#include <app/server/Server.h>
#include <esp_matter_providers.h>
#include <platform/ESP32/ConfigurationManagerImpl.h>
#include <platform/internal/GenericDeviceInstanceInfoProvider.ipp>
#include <app/server/CommissioningWindowManager.h>
#include <setup_payload/QRCodeSetupPayloadGenerator.h>
#include <setup_payload/ManualSetupPayloadGenerator.h>

#include <esp_openthread.h>
#include <esp_openthread_lock.h>
#include <esp_openthread_types.h>
#include <openthread/error.h>
#include <openthread/ip6.h>
#include <openthread/link.h>
#include <openthread/thread.h>
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

/* Vendor and product names from the init config (Basic Information allows
 * up to 32 characters each) */
static char s_vendor_name[33] = {0};
static char s_product_name[33] = {0};
/* Hardware version from the init config, -1 if not given */
static int s_hardware_version = -1;

/* ---------------------------------------------------------------------------
 * Device names
 *
 * The SDK's device info provider reports compile-time placeholders (TEST_VENDOR,
 * TEST_PRODUCT, TEST_VERSION) in the Basic Information cluster. This one
 * answers the vendor and product names and the hardware version from the
 * init config instead, and is otherwise the SDK's. The cluster keeps a reference to the provider it's
 * created with, so it's installed through esp-matter's custom provider hook
 * (CONFIG_CUSTOM_DEVICE_INSTANCE_INFO_PROVIDER), before the server starts.
 * --------------------------------------------------------------------------- */

using GenericInfoProvider = chip::DeviceLayer::Internal::GenericDeviceInstanceInfoProvider<
    chip::DeviceLayer::Internal::ESP32Config>;

class NamedDeviceInstanceInfoProvider : public GenericInfoProvider
{
public:
    NamedDeviceInstanceInfoProvider() :
        GenericInfoProvider(chip::DeviceLayer::ConfigurationManagerImpl::GetDefaultInstance())
    {}

    CHIP_ERROR GetVendorName(char *buf, size_t bufSize) override
    {
        return s_vendor_name[0] ? Copy(s_vendor_name, buf, bufSize) : GenericInfoProvider::GetVendorName(buf, bufSize);
    }

    CHIP_ERROR GetProductName(char *buf, size_t bufSize) override
    {
        return s_product_name[0] ? Copy(s_product_name, buf, bufSize) : GenericInfoProvider::GetProductName(buf, bufSize);
    }

    CHIP_ERROR GetHardwareVersion(uint16_t &hardwareVersion) override
    {
        if (s_hardware_version < 0) {
            return GenericInfoProvider::GetHardwareVersion(hardwareVersion);
        }
        hardwareVersion = static_cast<uint16_t>(s_hardware_version);
        return CHIP_NO_ERROR;
    }

    /* The version number, as the SDK's default string is TEST_VERSION */
    CHIP_ERROR GetHardwareVersionString(char *buf, size_t bufSize) override
    {
        if (s_hardware_version < 0) {
            return GenericInfoProvider::GetHardwareVersionString(buf, bufSize);
        }
        int len = snprintf(buf, bufSize, "%d", s_hardware_version);
        return (len < 0 || static_cast<size_t>(len) >= bufSize) ? CHIP_ERROR_BUFFER_TOO_SMALL : CHIP_NO_ERROR;
    }

private:
    static CHIP_ERROR Copy(const char *name, char *buf, size_t bufSize)
    {
        if (bufSize <= strlen(name)) {
            return CHIP_ERROR_BUFFER_TOO_SMALL;
        }
        strcpy(buf, name);
        return CHIP_NO_ERROR;
    }
};

static NamedDeviceInstanceInfoProvider s_info_provider;

/* Whether a Thread scan brought the IPv6 interface up, to take it back down */
static bool s_scan_ip6_enabled = false;


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

/* Extract an integer value from a proplist by atom key. Returns whether the
 * key was found with an integer value. */
static bool proplist_get_int(GlobalContext *global, term list,
                             const char *key_str, uint8_t key_len, int *out)
{
    UNUSED(key_len);
    term key_atom = globalcontext_make_atom(global, AtomString((const uint8_t *)key_str));
    for (term cur = list; term_is_nonempty_list(cur); cur = term_get_list_tail(cur)) {
        term head = term_get_list_head(cur);
        if (term_is_tuple(head) && term_get_tuple_arity(head) == 2
                && term_get_tuple_element(head, 0) == key_atom
                && term_is_integer(term_get_tuple_element(head, 1))) {
            *out = term_to_int(term_get_tuple_element(head, 1));
            return true;
        }
    }
    return false;
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
 * Running work on the CHIP task
 *
 * The CHIP stack must be used from its own task (or with its lock held), and
 * some of its calls need more stack than AtomVM's main task has: opening a
 * commissioning window overflows it. run_on_chip_task() runs fn(arg) on the
 * CHIP task and waits for it to finish. The CHIP task never waits on AtomVM,
 * so waiting here can't deadlock.
 * --------------------------------------------------------------------------- */

struct ChipWork {
    void (*fn)(void *arg);
    void *arg;
    SemaphoreHandle_t done;
};

static void chip_work_trampoline(intptr_t context)
{
    ChipWork *work = reinterpret_cast<ChipWork *>(context);
    work->fn(work->arg);
    xSemaphoreGive(work->done);
}

static bool run_on_chip_task(void (*fn)(void *arg), void *arg)
{
    static StaticSemaphore_t done_buf;
    static SemaphoreHandle_t done = xSemaphoreCreateBinaryStatic(&done_buf);

    ChipWork work = { fn, arg, done };
    if (chip::DeviceLayer::PlatformMgr().ScheduleWork(chip_work_trampoline,
            reinterpret_cast<intptr_t>(&work)) != CHIP_NO_ERROR) {
        return false;
    }
    xSemaphoreTake(done, portMAX_DELAY);
    return true;
}

/* ---------------------------------------------------------------------------
 * Thread scan
 * --------------------------------------------------------------------------- */

/* Ends a Thread scan: takes the IPv6 interface back down if the scan brought
 * it up, and tells the owner */
static void thread_scan_finish(void)
{
    if (s_scan_ip6_enabled) {
        otIp6SetEnabled(esp_openthread_get_instance(), false);
        s_scan_ip6_enabled = false;
    }
    send_atom_event(ATOM_STR("\x10", "thread_scan_done"));
}

/* Called on the OpenThread task, with its lock held, for each network found
 * and then with NULL when the scan is done */
static void thread_discover_cb(otActiveScanResult *result, void *context)
{
    UNUSED(context);

    if (result == NULL) {
        /* Radio counters since boot: whether frames went out, and whether
         * any 802.15.4 frames at all were heard */
        const otMacCounters *c = otLinkGetCounters(esp_openthread_get_instance());
        ESP_LOGI(TAG, "Thread scan done. MAC tx=%lu tx_abort=%lu tx_cca_fail=%lu tx_busy=%lu rx=%lu",
            (unsigned long) c->mTxTotal, (unsigned long) c->mTxErrAbort, (unsigned long) c->mTxErrCca,
            (unsigned long) c->mTxErrBusyChannel, (unsigned long) c->mRxTotal);

        thread_scan_finish();
        return;
    }

    if (s_owner_pid < 0 || s_global == NULL) return;

    size_t name_len = strnlen(result->mNetworkName.m8, OT_NETWORK_NAME_MAX_SIZE);

    /* Send {:thread_network, name, ext_pan_id, pan_id, channel, rssi} */
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(6) + TERM_BINARY_HEAP_SIZE(OT_NETWORK_NAME_MAX_SIZE)
            + TERM_BINARY_HEAP_SIZE(OT_EXT_PAN_ID_SIZE), heap);
    {
        term msg = term_alloc_tuple(6, &heap);
        term_put_tuple_element(msg, 0,
            globalcontext_make_atom(s_global, ATOM_STR("\xE", "thread_network")));
        term_put_tuple_element(msg, 1,
            term_from_literal_binary(result->mNetworkName.m8, name_len, &heap, s_global));
        term_put_tuple_element(msg, 2,
            term_from_literal_binary(result->mExtendedPanId.m8, OT_EXT_PAN_ID_SIZE, &heap, s_global));
        term_put_tuple_element(msg, 3, term_from_int(result->mPanId));
        term_put_tuple_element(msg, 4, term_from_int(result->mChannel));
        term_put_tuple_element(msg, 5, term_from_int(result->mRssi));
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

/* Identify: a controller asking the device to show which one it is, either
 * for a time (START, then STOP) or with a one-off effect (EFFECT) */
static esp_err_t matter_identification_cb(
    identification::callback_type_t type,
    uint16_t endpoint_id,
    uint8_t effect_id,
    uint8_t effect_variant,
    void *priv_data)
{
    UNUSED(effect_variant);
    UNUSED(priv_data);
    ESP_LOGI(TAG, "Identify callback: endpoint=%d type=%d effect=%d", endpoint_id, type, effect_id);
    if (s_owner_pid < 0 || s_global == NULL) return ESP_OK;

    AtomString type_atom;
    switch (type) {
        case identification::START: type_atom = ATOM_STR("\x5", "start"); break;
        case identification::STOP: type_atom = ATOM_STR("\x4", "stop"); break;
        case identification::EFFECT: type_atom = ATOM_STR("\x6", "effect"); break;
        default: return ESP_OK;
    }

    /* Send {:matter_identify, endpoint, type, effect_id} */
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(4), heap);
    {
        term msg = term_alloc_tuple(4, &heap);
        term_put_tuple_element(msg, 0,
            globalcontext_make_atom(s_global, ATOM_STR("\xF", "matter_identify")));
        term_put_tuple_element(msg, 1, term_from_int(endpoint_id));
        term_put_tuple_element(msg, 2, globalcontext_make_atom(s_global, type_atom));
        term_put_tuple_element(msg, 3, term_from_int(effect_id));
        port_send_message_from_task(s_global,
            term_from_local_process_id(s_owner_pid), msg);
    }
    END_WITH_STACK_HEAP(heap, s_global);

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

    /* XIAO ESP32-C6 antenna: GPIO3 low enables the RF switch, then GPIO14
     * picks the antenna (low = built-in ceramic, high = U.FL connector).
     * Start on the built-in one; the app picks with matter_nif:set_antenna/1
     * (Firefly has Seeed's 2.4 GHz antenna on the U.FL connector). */
    gpio_config_t ant_cfg = {
        .pin_bit_mask = (1ULL << GPIO_NUM_3) | (1ULL << GPIO_NUM_14),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&ant_cfg);
    gpio_set_level(GPIO_NUM_3, 0);
    gpio_set_level(GPIO_NUM_14, 0);
    ESP_LOGI(TAG, "Built-in antenna selected (GPIO3 low, GPIO14 low)");

    /* Names for the Basic Information cluster, see NamedDeviceInstanceInfoProvider */
    if (proplist_get_string(ctx->global, config,
            "\xB" "vendor_name", 11, s_vendor_name, sizeof(s_vendor_name)) > 0) {
        ESP_LOGI(TAG, "Vendor name: %s", s_vendor_name);
    }
    if (proplist_get_string(ctx->global, config,
            "\xC" "product_name", 12, s_product_name, sizeof(s_product_name)) > 0) {
        ESP_LOGI(TAG, "Product name: %s", s_product_name);
    }
    if (proplist_get_int(ctx->global, config, "\x10" "hardware_version", 16, &s_hardware_version)) {
        ESP_LOGI(TAG, "Hardware version: %d", s_hardware_version);
    }

    /* Create Matter node. (The Basic Information NodeLabel is a label users
     * give the device through their controller: it starts out empty.) */
    node::config_t node_config;

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

    /* Report our names in Basic Information, see NamedDeviceInstanceInfoProvider */
    esp_matter::set_custom_device_instance_info_provider(&s_info_provider);

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
            /* Extended Color Light. A new device starts on, with the color
             * mode set to hue/saturation; after that it comes back as it was
             * (StartUpOnOff, StartUpCurrentLevel and
             * StartUpColorTemperatureMireds null: the previous value, rather
             * than the SDK's defaults of off, the minimum level and 250
             * mireds). Controllers can still change those attributes. */
            extended_color_light::config_t config;
            config.on_off.on_off = true;
            config.on_off_lighting.start_up_on_off = nullable<uint8_t>();
            config.level_control.current_level = (uint8_t)64;
            config.level_control_lighting.start_up_current_level = nullable<uint8_t>();
            /* The whites Firefly.Lights.Color.from_mireds/1 covers: 6500K to 2000K */
            config.color_control_color_temperature.color_temp_physical_min_mireds = 153;
            config.color_control_color_temperature.color_temp_physical_max_mireds = 500;
            config.color_control_color_temperature.couple_color_temp_to_level_min_mireds = 153;
            config.color_control_color_temperature.start_up_color_temperature_mireds = nullable<uint16_t>();
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

    struct OpenWindow {
        uint16_t timeout_secs;
        CHIP_ERROR err;
    } open = { static_cast<uint16_t>(timeout_secs), CHIP_ERROR_INTERNAL };

    run_on_chip_task([](void *arg) {
        OpenWindow *open = static_cast<OpenWindow *>(arg);
        open->err = chip::Server::GetInstance().GetCommissioningWindowManager()
            .OpenBasicCommissioningWindow(chip::System::Clock::Seconds16(open->timeout_secs));
    }, &open);

    if (open.err != CHIP_NO_ERROR) {
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
 * matter_nif:commissioned/0 - Whether the device has been commissioned onto
 * at least one fabric (kept across reboots)
 * Returns: true | false
 */
static term nif_matter_commissioned(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    if (!s_started) {
        return FALSE_ATOM;
    }

    chip::DeviceLayer::PlatformMgr().LockChipStack();
    uint8_t fabrics = chip::Server::GetInstance().GetFabricTable().FabricCount();
    chip::DeviceLayer::PlatformMgr().UnlockChipStack();

    return fabrics > 0 ? TRUE_ATOM : FALSE_ATOM;
}

/*
 * matter_nif:thread_scan/0 - Start an MLE discovery scan of all channels for
 * Thread networks in range, without joining any. Results arrive as
 * {:thread_network, name, ext_pan_id, pan_id, channel, rssi} messages, then
 * :thread_scan_done.
 * Returns: :ok | {:error, reason}
 */
static term nif_matter_thread_scan(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    if (!s_started) {
        return make_error(ctx, globalcontext_make_atom(ctx->global, ATOM_STR("\xF", "not_initialized")));
    }

    otInstance *instance = esp_openthread_get_instance();
    esp_openthread_lock_acquire(portMAX_DELAY);

    /* Discovery needs the IPv6 interface up, which it isn't until the device
     * joins a network: bring it up for the scan (the callback takes it back
     * down) */
    if (!otIp6IsEnabled(instance)) {
        otIp6SetEnabled(instance, true);
        s_scan_ip6_enabled = true;
    }

    otError err = otThreadDiscover(instance, 0 /* all channels */, OT_PANID_BROADCAST,
        false, false, thread_discover_cb, NULL);

    if (err != OT_ERROR_NONE && s_scan_ip6_enabled) {
        otIp6SetEnabled(instance, false);
        s_scan_ip6_enabled = false;
    }

    esp_openthread_lock_release();

    if (err != OT_ERROR_NONE) {
        ESP_LOGE(TAG, "Thread scan failed to start: %s", otThreadErrorToString(err));
        return make_error(ctx, term_from_int(err));
    }

    ESP_LOGI(TAG, "Thread scan started");
    return OK_ATOM;
}

/*
 * matter_nif:get_attribute/3 - Read an attribute's value
 * Args: endpoint_id, cluster_id, attribute_id (integers)
 * Returns: {:ok, value} (booleans as 0/1, like {:matter_write, ...} values;
 *          a null value as the type's null, e.g. 255 for a nullable u8) |
 *          {:error, :not_found}
 */
static term nif_matter_get_attribute(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (!term_is_integer(argv[0]) || !term_is_integer(argv[1]) || !term_is_integer(argv[2])) {
        RAISE_ERROR(BADARG_ATOM);
    }

    uint16_t endpoint_id = (uint16_t) term_to_int(argv[0]);
    uint32_t cluster_id = (uint32_t) term_to_int(argv[1]);
    uint32_t attribute_id = (uint32_t) term_to_int(argv[2]);

    esp_matter_attr_val_t val = esp_matter_invalid(NULL);
    chip::DeviceLayer::PlatformMgr().LockChipStack();
    esp_err_t err = attribute::get_val(endpoint_id, cluster_id, attribute_id, &val);
    chip::DeviceLayer::PlatformMgr().UnlockChipStack();

    if (err != ESP_OK) {
        return make_error(ctx, globalcontext_make_atom(ctx->global, ATOM_STR("\x9", "not_found")));
    }

    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term t = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(t, 0, OK_ATOM);
    term_put_tuple_element(t, 1, term_from_int(attr_val_to_int(&val)));
    return t;
}

/*
 * matter_nif:thread_status/0 - The device's Thread role, and how many Thread
 * devices it's in touch with: its neighbors, or for a child its parent. (A
 * leader with none has made a network of its own, reaching nobody.)
 * Returns: {:disabled | :detached | :child | :router | :leader, neighbors}
 */
static term nif_matter_thread_status(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

    otDeviceRole role = OT_DEVICE_ROLE_DISABLED;
    int neighbors = 0;

    if (s_started) {
        otInstance *instance = esp_openthread_get_instance();
        esp_openthread_lock_acquire(portMAX_DELAY);

        role = otThreadGetDeviceRole(instance);
        otNeighborInfoIterator iterator = OT_NEIGHBOR_INFO_ITERATOR_INIT;
        otNeighborInfo info;
        while (otThreadGetNextNeighborInfo(instance, &iterator, &info) == OT_ERROR_NONE) {
            neighbors++;
        }
        otRouterInfo parent;
        if (role == OT_DEVICE_ROLE_CHILD && neighbors == 0
                && otThreadGetParentInfo(instance, &parent) == OT_ERROR_NONE) {
            neighbors = 1;
        }

        esp_openthread_lock_release();
    }

    AtomString role_atom;
    switch (role) {
        case OT_DEVICE_ROLE_DETACHED: role_atom = ATOM_STR("\x8", "detached"); break;
        case OT_DEVICE_ROLE_CHILD: role_atom = ATOM_STR("\x5", "child"); break;
        case OT_DEVICE_ROLE_ROUTER: role_atom = ATOM_STR("\x6", "router"); break;
        case OT_DEVICE_ROLE_LEADER: role_atom = ATOM_STR("\x6", "leader"); break;
        default: role_atom = ATOM_STR("\x8", "disabled"); break;
    }

    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term t = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(t, 0, globalcontext_make_atom(ctx->global, role_atom));
    term_put_tuple_element(t, 1, term_from_int(neighbors));
    return t;
}

/*
 * matter_nif:set_antenna/1 - Select the XIAO ESP32-C6's antenna: :internal
 * (built-in ceramic), :external (U.FL connector), or :switch_off (RF switch
 * control disabled, the board's power-on state). For testing reception;
 * init selects :internal.
 * Returns: :ok | {:error, :badarg}
 */
static term nif_matter_set_antenna(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    term which = argv[0];
    int enable_level, select_level;
    if (which == globalcontext_make_atom(ctx->global, ATOM_STR("\x8", "internal"))) {
        enable_level = 0;
        select_level = 0;
    } else if (which == globalcontext_make_atom(ctx->global, ATOM_STR("\x8", "external"))) {
        enable_level = 0;
        select_level = 1;
    } else if (which == globalcontext_make_atom(ctx->global, ATOM_STR("\xA", "switch_off"))) {
        enable_level = 1;
        select_level = 0;
    } else {
        return make_error(ctx, BADARG_ATOM);
    }

    gpio_set_level(GPIO_NUM_3, enable_level);
    gpio_set_level(GPIO_NUM_14, select_level);
    ESP_LOGI(TAG, "Antenna: GPIO3 %d, GPIO14 %d", enable_level, select_level);
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
        run_on_chip_task([](void *) {
            chip::Server::GetInstance().GetCommissioningWindowManager().CloseCommissioningWindow();
        }, NULL);
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
static const struct Nif matter_thread_status_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_thread_status };
static const struct Nif matter_get_attribute_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_get_attribute };
static const struct Nif matter_set_antenna_nif  = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_set_antenna };
static const struct Nif matter_thread_scan_nif  = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_thread_scan };
static const struct Nif matter_commissioned_nif = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_matter_commissioned };
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
    if (strcmp("matter_nif:commissioned/0", nifname) == 0)            return &matter_commissioned_nif;
    if (strcmp("matter_nif:thread_scan/0", nifname) == 0)             return &matter_thread_scan_nif;
    if (strcmp("matter_nif:set_antenna/1", nifname) == 0)             return &matter_set_antenna_nif;
    if (strcmp("matter_nif:get_attribute/3", nifname) == 0)           return &matter_get_attribute_nif;
    if (strcmp("matter_nif:thread_status/0", nifname) == 0)           return &matter_thread_status_nif;
    if (strcmp("matter_nif:open_commissioning_window/1", nifname) == 0) return &matter_open_comm_nif;
    if (strcmp("matter_nif:close_commissioning_window/0", nifname) == 0) return &matter_close_comm_nif;
    if (strcmp("matter_nif:factory_reset/0", nifname) == 0)           return &matter_factory_reset_nif;
    if (strcmp("matter_nif:get_setup_codes/0", nifname) == 0)        return &matter_get_setup_codes_nif;
    if (strcmp("matter_nif:respond_read/4", nifname) == 0)            return &matter_respond_read_nif;
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_matter, NULL, NULL, atomvm_matter_resolve_nif)

} /* extern "C" */

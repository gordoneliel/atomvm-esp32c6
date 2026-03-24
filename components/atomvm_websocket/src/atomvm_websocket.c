/*
 * atomvm_websocket.c - WebSocket client NIF for AtomVM on ESP32
 *
 * Wraps ESP-IDF's esp_websocket_client to provide WebSocket connectivity.
 *
 * NIFs:
 *   websocket_nif:connect/2    - Connect to a WebSocket server (pid, url)
 *   websocket_nif:connect/3    - Connect with custom HTTP headers (pid, url, headers)
 *   websocket_nif:send_text/1  - Send a text frame
 *   websocket_nif:send_binary/1 - Send a binary frame
 *   websocket_nif:close/0      - Close the connection
 *   websocket_nif:is_connected/0 - Check connection status
 *
 * Events sent to owner process:
 *   {:ws_connected}
 *   {:ws_data, binary}
 *   {:ws_disconnected}
 *   {:ws_error}
 */

#include <sdkconfig.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* AtomVM headers */
#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <port.h>
#include <portnifloader.h>
#include <term.h>

/* ESP-IDF headers */
#include <esp_log.h>
#include <esp_crt_bundle.h>
#include <esp_websocket_client.h>

#define TAG "atomvm_ws"

/* ---------------------------------------------------------------------------
 * Module state
 * --------------------------------------------------------------------------- */

static GlobalContext *s_global = NULL;
static int32_t s_owner_pid = -1;
static esp_websocket_client_handle_t s_ws_client = NULL;
static bool s_connected = false;
static char *s_headers = NULL;

/* ---------------------------------------------------------------------------
 * Helper: send event to owner Erlang process from ESP-IDF task
 * --------------------------------------------------------------------------- */

static inline term make_atom(GlobalContext *global, AtomString atom_str)
{
    return globalcontext_make_atom(global, atom_str);
}

static void send_atom_event(term a)
{
    if (s_owner_pid < 0 || s_global == NULL) return;

    /* Send a bare atom as the message (no tuple wrapper needed) */
    BEGIN_WITH_STACK_HEAP(0, heap);
    {
        port_send_message_from_task(s_global,
            term_from_local_process_id(s_owner_pid), a);
    }
    END_WITH_STACK_HEAP(heap, s_global);
}

static void send_data_event(const char *data, int data_len)
{
    if (s_owner_pid < 0 || s_global == NULL || data == NULL || data_len <= 0) return;

    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(2) + term_binary_heap_size(data_len), heap);
    {
        term bin = term_from_literal_binary(data, data_len, &heap, s_global);
        term msg = port_heap_create_tuple2(&heap,
            make_atom(s_global, ATOM_STR("\x7", "ws_data")),
            bin);
        port_send_message_from_task(s_global,
            term_from_local_process_id(s_owner_pid), msg);
    }
    END_WITH_STACK_HEAP(heap, s_global);
}

/* ---------------------------------------------------------------------------
 * WebSocket event handler (runs in esp_websocket_client task)
 * --------------------------------------------------------------------------- */

static void ws_event_handler(void *handler_args, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    esp_websocket_event_data_t *ws_data = (esp_websocket_event_data_t *)event_data;

    switch (event_id) {
    case WEBSOCKET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "WebSocket connected");
        s_connected = true;
        send_atom_event(make_atom(s_global, ATOM_STR("\xC", "ws_connected")));
        break;

    case WEBSOCKET_EVENT_DATA:
        if (ws_data->data_len > 0 && ws_data->data_ptr != NULL) {
            ESP_LOGD(TAG, "WS data: len=%d, opcode=%d", ws_data->data_len, ws_data->op_code);
            send_data_event(ws_data->data_ptr, ws_data->data_len);
        }
        break;

    case WEBSOCKET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "WebSocket disconnected");
        s_connected = false;
        send_atom_event(make_atom(s_global, ATOM_STR("\xF", "ws_disconnected")));
        break;

    case WEBSOCKET_EVENT_ERROR:
        ESP_LOGE(TAG, "WebSocket error");
        send_atom_event(make_atom(s_global, ATOM_STR("\x8", "ws_error")));
        break;

    case WEBSOCKET_EVENT_CLOSED:
        ESP_LOGI(TAG, "WebSocket closed");
        s_connected = false;
        send_atom_event(make_atom(s_global, ATOM_STR("\xF", "ws_disconnected")));
        break;

    default:
        break;
    }
}

/* ===========================================================================
 * NIF implementations
 * =========================================================================== */

/*
 * Internal: shared connect logic
 *
 * pid, url are required. headers_bin may be term_invalid() to skip.
 */
static term ws_connect_internal(Context *ctx, term pid, term url_term, term headers_term)
{
    /* If already connected, close first */
    if (s_ws_client != NULL) {
        esp_websocket_client_close(s_ws_client, portMAX_DELAY);
        esp_websocket_client_destroy(s_ws_client);
        s_ws_client = NULL;
        s_connected = false;
    }

    /* Free old headers */
    if (s_headers != NULL) {
        free(s_headers);
        s_headers = NULL;
    }

    /* Store owner */
    s_global = ctx->global;
    s_owner_pid = term_to_local_process_id(pid);

    /* Extract URL */
    if (!term_is_binary(url_term)) {
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\x7", "bad_url")));
        return t;
    }

    int url_len = term_binary_size(url_term);
    char *url = malloc(url_len + 1);
    if (!url) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    memcpy(url, term_binary_data(url_term), url_len);
    url[url_len] = '\0';

    /* Extract headers if provided */
    if (term_is_binary(headers_term) && term_binary_size(headers_term) > 0) {
        int hdr_len = term_binary_size(headers_term);
        s_headers = malloc(hdr_len + 1);
        if (s_headers) {
            memcpy(s_headers, term_binary_data(headers_term), hdr_len);
            s_headers[hdr_len] = '\0';
            ESP_LOGI(TAG, "Using custom headers (%d bytes)", hdr_len);
        }
    }

    ESP_LOGI(TAG, "Connecting to %s", url);

    esp_websocket_client_config_t config = {
        .uri = url,
        .task_stack = 4096,
        .buffer_size = 2048,
        .headers = s_headers,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    s_ws_client = esp_websocket_client_init(&config);
    free(url);

    if (s_ws_client == NULL) {
        ESP_LOGE(TAG, "Failed to init websocket client");
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xB", "init_failed")));
        return t;
    }

    esp_websocket_register_events(s_ws_client, WEBSOCKET_EVENT_ANY,
                                   ws_event_handler, NULL);

    esp_err_t err = esp_websocket_client_start(s_ws_client);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start websocket client: %d", err);
        esp_websocket_client_destroy(s_ws_client);
        s_ws_client = NULL;
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xC", "start_failed")));
        return t;
    }

    return OK_ATOM;
}

/*
 * websocket_nif:connect/2 - Connect to a WebSocket server
 *
 * Args: pid (self()), url (binary)
 * Returns: :ok | {:error, reason}
 */
static term nif_ws_connect(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    return ws_connect_internal(ctx, argv[0], argv[1], term_invalid_term());
}

/*
 * websocket_nif:connect/3 - Connect with custom HTTP headers
 *
 * Args: pid (self()), url (binary), headers (binary, "Name: Value\r\n..." format)
 * Returns: :ok | {:error, reason}
 */
static term nif_ws_connect_opts(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    return ws_connect_internal(ctx, argv[0], argv[1], argv[2]);
}

/*
 * websocket_nif:send_text/1 - Send a text frame
 *
 * Args: data (binary)
 * Returns: :ok | {:error, reason}
 */
static term nif_ws_send_text(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (s_ws_client == NULL || !s_connected) {
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xD", "not_connected")));
        return t;
    }

    if (!term_is_binary(argv[0])) {
        return ERROR_ATOM;
    }

    const char *data = term_binary_data(argv[0]);
    int len = term_binary_size(argv[0]);

    int sent = esp_websocket_client_send_text(s_ws_client, data, len, portMAX_DELAY);
    if (sent < 0) {
        ESP_LOGE(TAG, "send_text failed: %d", sent);
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xB", "send_failed")));
        return t;
    }

    return OK_ATOM;
}

/*
 * websocket_nif:send_binary/1 - Send a binary frame
 *
 * Args: data (binary)
 * Returns: :ok | {:error, reason}
 */
static term nif_ws_send_binary(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (s_ws_client == NULL || !s_connected) {
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xD", "not_connected")));
        return t;
    }

    if (!term_is_binary(argv[0])) {
        return ERROR_ATOM;
    }

    const char *data = term_binary_data(argv[0]);
    int len = term_binary_size(argv[0]);

    int sent = esp_websocket_client_send_bin(s_ws_client, data, len, portMAX_DELAY);
    if (sent < 0) {
        ESP_LOGE(TAG, "send_binary failed: %d", sent);
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1,
            globalcontext_make_atom(ctx->global, ATOM_STR("\xB", "send_failed")));
        return t;
    }

    return OK_ATOM;
}

/*
 * websocket_nif:close/0 - Close the WebSocket connection
 *
 * Returns: :ok
 */
static term nif_ws_close(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    if (s_ws_client != NULL) {
        ESP_LOGI(TAG, "Closing WebSocket connection");
        esp_websocket_client_close(s_ws_client, pdMS_TO_TICKS(5000));
        esp_websocket_client_destroy(s_ws_client);
        s_ws_client = NULL;
        s_connected = false;
    }

    return OK_ATOM;
}

/*
 * websocket_nif:is_connected/0 - Check if WebSocket is connected
 *
 * Returns: true | false
 */
static term nif_ws_is_connected(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    if (s_ws_client != NULL && esp_websocket_client_is_connected(s_ws_client)) {
        return TRUE_ATOM;
    }
    return FALSE_ATOM;
}

/* ===========================================================================
 * NIF registration
 * =========================================================================== */

static const struct Nif ws_connect_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ws_connect
};

static const struct Nif ws_connect_opts_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ws_connect_opts
};

static const struct Nif ws_send_text_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ws_send_text
};

static const struct Nif ws_send_binary_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ws_send_binary
};

static const struct Nif ws_close_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ws_close
};

static const struct Nif ws_is_connected_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_ws_is_connected
};

void atomvm_websocket_nif_init(GlobalContext *global)
{
    UNUSED(global);
    ESP_LOGI(TAG, "atomvm_websocket component loaded");
}

const struct Nif *atomvm_websocket_nif_get_nif(const char *nifname)
{
    if (strcmp("websocket_nif:connect/2", nifname) == 0) {
        return &ws_connect_nif;
    }
    if (strcmp("websocket_nif:connect/3", nifname) == 0) {
        return &ws_connect_opts_nif;
    }
    if (strcmp("websocket_nif:send_text/1", nifname) == 0) {
        return &ws_send_text_nif;
    }
    if (strcmp("websocket_nif:send_binary/1", nifname) == 0) {
        return &ws_send_binary_nif;
    }
    if (strcmp("websocket_nif:close/0", nifname) == 0) {
        return &ws_close_nif;
    }
    if (strcmp("websocket_nif:is_connected/0", nifname) == 0) {
        return &ws_is_connected_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_websocket, atomvm_websocket_nif_init, NULL, atomvm_websocket_nif_get_nif)

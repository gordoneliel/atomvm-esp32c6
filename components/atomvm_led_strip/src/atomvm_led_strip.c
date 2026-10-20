/*
 * atomvm_led_strip.c - WS2812B LED strip NIF for AtomVM on ESP32
 *
 * Wraps ESP-IDF's led_strip component (RMT backend) for addressable LEDs.
 *
 * NIFs:
 *   led_strip_nif:init/2      - init(gpio, num_leds) -> :ok | {:error, reason}
 *   led_strip_nif:set_pixel/4 - set_pixel(index, r, g, b) -> :ok
 *   led_strip_nif:fill/3      - fill(r, g, b) -> :ok
 *   led_strip_nif:refresh/0   - refresh() -> :ok
 *   led_strip_nif:clear/0     - clear() -> :ok
 */

#include <sdkconfig.h>
#include <string.h>

#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

#include <esp_log.h>
#include <led_strip.h>

#define TAG "atomvm_led_strip"

static led_strip_handle_t s_strip = NULL;
static int s_num_leds = 0;

/* ---------------------------------------------------------------------------
 * NIF: led_strip_nif:init/2
 * Args: gpio_pin (int), num_leds (int)
 * Returns: :ok | {:error, reason}
 * --------------------------------------------------------------------------- */
static term nif_led_strip_init(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);

    if (s_strip != NULL) {
        ESP_LOGW(TAG, "Already initialized");
        return OK_ATOM;
    }

    int gpio = term_to_int(argv[0]);
    int num_leds = term_to_int(argv[1]);

    ESP_LOGI(TAG, "Initializing %d WS2812B LEDs on GPIO %d", num_leds, gpio);

    led_strip_config_t strip_config = {
        .strip_gpio_num = gpio,
        .max_leds = num_leds,
        .led_model = LED_MODEL_WS2812,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
        .flags = { .invert_out = false },
    };

    led_strip_rmt_config_t rmt_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10 * 1000 * 1000, /* 10 MHz */
        .mem_block_symbols = 64,
        .flags = { .with_dma = false },
    };

    esp_err_t err = led_strip_new_rmt_device(&strip_config, &rmt_config, &s_strip);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "led_strip_new_rmt_device failed: %d", err);
        if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2)) != MEMORY_GC_OK)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        term t = term_alloc_tuple(2, &ctx->heap);
        term_put_tuple_element(t, 0, ERROR_ATOM);
        term_put_tuple_element(t, 1, term_from_int(err));
        return t;
    }

    s_num_leds = num_leds;

    /* Start with all LEDs off */
    led_strip_clear(s_strip);

    ESP_LOGI(TAG, "LED strip ready (%d LEDs on GPIO %d)", num_leds, gpio);
    return OK_ATOM;
}

/* ---------------------------------------------------------------------------
 * NIF: led_strip_nif:set_pixel/4
 * Args: index (int), r (int), g (int), b (int)
 * Returns: :ok
 * --------------------------------------------------------------------------- */
static term nif_led_strip_set_pixel(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);

    if (!s_strip) return ERROR_ATOM;

    int index = term_to_int(argv[0]);
    int r = term_to_int(argv[1]);
    int g = term_to_int(argv[2]);
    int b = term_to_int(argv[3]);

    if (index < 0 || index >= s_num_leds) return ERROR_ATOM;

    led_strip_set_pixel(s_strip, index, r, g, b);
    return OK_ATOM;
}

/* ---------------------------------------------------------------------------
 * NIF: led_strip_nif:fill/3
 * Args: r (int), g (int), b (int)
 * Returns: :ok
 * --------------------------------------------------------------------------- */
static term nif_led_strip_fill(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);

    if (!s_strip) return ERROR_ATOM;

    int r = term_to_int(argv[0]);
    int g = term_to_int(argv[1]);
    int b = term_to_int(argv[2]);

    for (int i = 0; i < s_num_leds; i++) {
        led_strip_set_pixel(s_strip, i, r, g, b);
    }
    return OK_ATOM;
}

/* ---------------------------------------------------------------------------
 * NIF: led_strip_nif:refresh/0
 * Returns: :ok
 * --------------------------------------------------------------------------- */
static term nif_led_strip_refresh(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    if (!s_strip) return ERROR_ATOM;

    led_strip_refresh(s_strip);
    return OK_ATOM;
}

/* ---------------------------------------------------------------------------
 * NIF: led_strip_nif:clear/0
 * Returns: :ok
 * --------------------------------------------------------------------------- */
static term nif_led_strip_clear(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    UNUSED(argv);

    if (!s_strip) return ERROR_ATOM;

    led_strip_clear(s_strip);
    return OK_ATOM;
}

/* ===========================================================================
 * NIF registration
 * =========================================================================== */

static const struct Nif led_strip_init_nif      = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_led_strip_init };
static const struct Nif led_strip_set_pixel_nif  = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_led_strip_set_pixel };
static const struct Nif led_strip_fill_nif       = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_led_strip_fill };
static const struct Nif led_strip_refresh_nif    = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_led_strip_refresh };
static const struct Nif led_strip_clear_nif      = { .base = { .type = NIFFunctionType }, .nif_ptr = nif_led_strip_clear };

static const struct Nif *atomvm_led_strip_resolve_nif(const char *nifname)
{
    if (strcmp("led_strip_nif:init/2", nifname) == 0)      return &led_strip_init_nif;
    if (strcmp("led_strip_nif:set_pixel/4", nifname) == 0) return &led_strip_set_pixel_nif;
    if (strcmp("led_strip_nif:fill/3", nifname) == 0)      return &led_strip_fill_nif;
    if (strcmp("led_strip_nif:refresh/0", nifname) == 0)   return &led_strip_refresh_nif;
    if (strcmp("led_strip_nif:clear/0", nifname) == 0)     return &led_strip_clear_nif;
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_led_strip, NULL, NULL, atomvm_led_strip_resolve_nif)

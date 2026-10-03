/* SPDX-License-Identifier: Apache-2.0 */
/* Hardware facts and drivers: FoloToy/ai-passport, pinned in
 * components/passport_bsp/UPSTREAM.md. All pins remain in bsp_pins.h.
 * Muse owns codec open/close after audio_init; the vendor BSP is only used
 * for construction and the initial validated fixed-format open. */
#include "bsp_audio.h"
#include "bsp_battery.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_i2c.h"
#include "bsp_pins.h"
#include "esp_check.h"
#include "esp_log.h"
#include "muse_audio.h"
#include "muse_board.h"
#include "muse_state.h"

static const char *TAG = "passport";
static unsigned s_edges;
static bool s_battery;

/* Callback only records edges. LVGL, network and audio work stay on Muse's
 * existing tasks. Never read the shared ADC from a second owner. */
static void button_event(bsp_btn_t button, bsp_btn_ev_t event, void *user)
{
    (void)user;
    unsigned edge = 0;
    if (button == BSP_BTN_OK) {
        edge = event == BSP_BTN_PRESS ? MUSE_BTN_TALK_PRESS
             : event == BSP_BTN_RELEASE ? MUSE_BTN_TALK_RELEASE : 0;
    } else if (button == BSP_BTN_DOWN) {
        edge = event == BSP_BTN_PRESS ? MUSE_BTN_AUX_PRESS
             : event == BSP_BTN_RELEASE ? MUSE_BTN_AUX_RELEASE : 0;
    } else if (button == BSP_BTN_UP && event == BSP_BTN_PRESS) {
        edge = MUSE_BTN_PREV_PRESS;
    }
    if (edge) __atomic_fetch_or(&s_edges, edge, __ATOMIC_RELAXED);
}

static esp_err_t init(void)
{
    ESP_RETURN_ON_ERROR(bsp_i2c_init(), TAG, "shared i2c");
    /* The callback is attached by display_start, after muse_state_init. */
    s_battery = bsp_battery_init() == ESP_OK;
    if (!s_battery) ESP_LOGW(TAG, "battery gauge unavailable");
    return ESP_OK;
}

static lv_display_t *display_start(lv_indev_t **touch)
{
    *touch = NULL;
    if (bsp_display_init() != ESP_OK) return NULL;
    lv_display_t *display = bsp_lvgl_init();
    if (!display || bsp_button_init(button_event, NULL) != ESP_OK) return NULL;
    return display;
}

static void set_brightness(int pct)
{
    bsp_display_backlight(pct < 0 ? 0 : pct > 100 ? 100 : pct);
}

static esp_err_t audio_init(esp_codec_dev_handle_t *speaker, esp_codec_dev_handle_t *mic)
{
    ESP_RETURN_ON_ERROR(bsp_audio_init(), TAG, "audio construction");
    ESP_RETURN_ON_ERROR(bsp_audio_set_format(MUSE_AUDIO_RATE, 16, 2), TAG, "audio format");
    *speaker = *mic = bsp_audio_codec_handle();
    return *speaker ? ESP_OK : ESP_FAIL;
}

static unsigned poll_buttons(void)
{
    return __atomic_exchange_n(&s_edges, 0, __ATOMIC_RELAXED);
}

static esp_err_t read_power(muse_power_t *out)
{
    *out = (muse_power_t){ .battery_pct = -1 };
    if (!s_battery) return ESP_ERR_NOT_FOUND;
    out->battery_pct = bsp_battery_soc();
    int mv = bsp_battery_mv();
    out->battery_mv = mv < 0 ? 0 : mv;
    /* There is no board-defined charge/USB detection. Leave both fields
     * unset rather than inferring a charging indicator from voltage. */
    return out->battery_pct < 0 ? ESP_FAIL : ESP_OK;
}

static esp_err_t power_off(void)
{
    /* The vendor baseline only verifies timed deep-sleep wake. A permanent
     * shutdown would strand this ADC-key device until reset. */
    return ESP_ERR_NOT_SUPPORTED;
}

static const muse_board_t s_board = {
    .name = "FoloToy AI Passport",
    .width = BSP_LCD_W,
    .height = BSP_LCD_H,
    .round = false,
    .touch = false,
    .talk_button = "OK",
    .aux_button = "DOWN",
    .frame_ms = 100,
    .init = init,
    .display_start = display_start,
    .display_lock = bsp_lvgl_lock,
    .display_unlock = bsp_lvgl_unlock,
    .set_brightness = set_brightness,
    .audio_init = audio_init,
    .mic_slot = 0,
    .poll_buttons = poll_buttons,
    .read_power = read_power,
    .power_off = power_off,
};

const muse_board_t *muse_board_get(void) { return &s_board; }

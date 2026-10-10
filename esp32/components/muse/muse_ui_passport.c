/* SPDX-License-Identifier: Apache-2.0 */
/* A small portrait UI for the Passport. No full-screen image or canvas
 * allocation: the vendor display port uses a single partial DMA buffer. */
#include "muse_ui.h"

#include <stdio.h>
#include <string.h>
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "src/misc/lv_text_private.h"
#include "muse_ble.h"
#include "muse_board.h"
#include "muse_link.h"
#include "muse_menu.h"
#include "muse_passport_reader.h"
#include "muse_settings.h"
#include "muse_state.h"
#include "muse_locale.h"
#include "muse_speech.h"
#include "passport_avatar.h"

static const char *TAG = "passport_ui";
static lv_obj_t *s_status, *s_face, *s_reply, *s_footer, *s_power, *s_page_info;
static lv_obj_t *s_pair, *s_pair_title, *s_pair_detail;
static uint32_t s_caption_version;
static volatile bool s_dark;
static int s_preview = -1;
static int s_brightness = -1;
static bool s_ready;
static bool s_reader_visible;
static lv_font_t s_text_font;
LV_FONT_DECLARE(passport_font_16);

static lv_obj_t *label(lv_obj_t *parent, const lv_font_t *font,
                       int x, int y, int width, int height)
{
    lv_obj_t *obj = lv_label_create(parent);
    lv_obj_set_style_text_font(obj, font, 0);
    lv_obj_set_style_text_color(obj, lv_color_hex(0xdad5eb), 0);
    lv_obj_set_style_text_line_space(obj, 2, 0);
    lv_obj_set_size(obj, width, height);
    lv_obj_set_pos(obj, x, y);
    lv_label_set_long_mode(obj, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text(obj, "");
    return obj;
}

static void set_text(lv_obj_t *obj, const char *text)
{
    if (strcmp(lv_label_get_text(obj), text)) lv_label_set_text(obj, text);
}

static void brightness(void)
{
    int pct = s_dark ? 0 : s_preview >= 0 ? s_preview : muse_settings_brightness();
    if (pct != s_brightness) {
        muse_board->set_brightness(pct);
        s_brightness = pct;
    }
}

static const char *passport_link_name(muse_link_state_t link)
{
    static const char *const names[] = {
        "正在启动", "请在 Muse App 配对", "手机已连接", "请确认配对",
        "请连接手机", "已连接", "连接已断开", "连接失败"
    };
    return link >= MUSE_LINK_BOOT && link <= MUSE_LINK_ERROR ? names[link] : "请连接手机";
}

static void frame(lv_timer_t *timer)
{
    (void)timer;
    s_dark = muse_state_asleep();
    brightness();
    if (s_dark) return;
    float mode_secs;
    muse_mode_t mode = muse_state_mode(&mode_secs);
    float now = (float)esp_timer_get_time() / 1e6f;
    if (mode == MUSE_MODE_LISTENING) muse_menu_close();
    /* Keep the pairing overlay current even while settings are open. */
    bool menu = muse_menu_tick(now);
    static bool previous_menu;
    static int menu_probe;
    if (menu && !previous_menu) menu_probe = 10;
    if (menu_probe && --menu_probe == 0) {
        ESP_LOGI(TAG, "menu stack free=%u heap=%u largest=%u",
                 (unsigned)uxTaskGetStackHighWaterMark(NULL),
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    }
    previous_menu = menu;

    static const char *const modes[MUSE_MODE_COUNT] = {
        MUSE_UI_TEXT("STARTING", "正在启动"), MUSE_UI_TEXT("READY", "准备就绪"), MUSE_UI_TEXT("LISTENING", "正在聆听"), MUSE_UI_TEXT("WAITING FOR MUSE", "等待 Muse 回复"),
        MUSE_UI_TEXT("MUSE REPLIED", "Muse 已回复"), MUSE_UI_TEXT("PLEASE TRY AGAIN", "请重试"), MUSE_UI_TEXT("GOODBYE", "再见")
    };
    muse_link_state_t link = muse_link_state();
    const char *status = mode == MUSE_MODE_IDLE && link != MUSE_LINK_ONLINE
                       ? passport_link_name(link) : modes[mode];
    set_text(s_status, status);
    char caption[MUSE_CAPTION_MAX];
    muse_passport_page_t page = {0};
    bool reading = mode != MUSE_MODE_LISTENING && mode != MUSE_MODE_OFF
                && muse_passport_reader_page(&page);
    bool changed;
    if (reading) {
        snprintf(caption, sizeof(caption), "%s", page.text);
        changed = strcmp(lv_label_get_text(s_reply), caption) != 0;
    } else {
        if (s_reader_visible) s_caption_version = UINT32_MAX;
        changed = muse_state_caption(caption, sizeof(caption), &s_caption_version);
    }
    s_reader_visible = reading;
    static const lv_image_dsc_t *shown_avatar;
    if (!menu) {
        muse_mode_t avatar_mode = muse_speech_started() ? MUSE_MODE_SPEAKING : mode;
        const lv_image_dsc_t *avatar = passport_avatar_frame(avatar_mode, reading, (unsigned)(now * 10), muse_state_level());
        if (shown_avatar != avatar) { lv_image_set_src(s_face, avatar); shown_avatar = avatar; }
        lv_obj_set_pos(s_face, reading ? 20 : 56, reading ? 49 : 71);
    }
    lv_obj_set_pos(s_reply, 20, reading ? 108 : 213);
    lv_obj_set_height(s_reply, reading ? 161 : 64);
    lv_obj_set_flag(s_page_info, LV_OBJ_FLAG_HIDDEN, !reading);
    if (changed) {
        uint32_t at = 0;
        while (caption[at]) {
            uint32_t cp = lv_text_encoded_next(caption, &at);
            lv_font_glyph_dsc_t dsc;
            if (cp >= 0x80 && !s_text_font.get_glyph_dsc(&s_text_font, &dsc, cp, 0)) {
                ESP_LOGW(TAG, "caption missing glyph U+%04lx", (unsigned long)cp);
            }
        }
        set_text(s_reply, caption);
    }
    if (!reading && mode == MUSE_MODE_IDLE && !lv_label_get_text(s_reply)[0]) {
        set_text(s_reply, "按住 OK，和我说话吧");
    }
    muse_power_t power = muse_state_power();
    char battery[16];
    if (power.battery_pct >= 0) snprintf(battery, sizeof(battery), "%d%%", power.battery_pct);
    else snprintf(battery, sizeof(battery), "--");
    set_text(s_power, battery);

    muse_ble_status_t ble;
    muse_ble_status(&ble);
    bool confirm = link == MUSE_LINK_CONFIRM;
    bool pairing = confirm || ble.passkey;
    lv_obj_set_flag(s_pair, LV_OBJ_FLAG_HIDDEN, !pairing);
    if (pairing) {
        set_text(s_pair_title, confirm ? MUSE_UI_TEXT("Muse app pairing", "Muse 账号配对") : MUSE_UI_TEXT("Pairing code", "蓝牙配对码"));
        char detail[96];
        if (confirm) snprintf(detail, sizeof(detail), MUSE_UI_TEXT("Press OK to confirm", "按 OK 确认配对"));
        else snprintf(detail, sizeof(detail), MUSE_UI_TEXT("%06u\nEnter on your phone", "%06u\n请在手机输入"), (unsigned)ble.passkey);
        set_text(s_pair_detail, detail);
    }
    if (reading && !pairing) {
        set_text(s_status, link != MUSE_LINK_ONLINE ? passport_link_name(link)
                 : muse_speech_started() ? "正在朗读"
                 : page.assistant ? MUSE_UI_TEXT("MUSE REPLIED", "Muse 已回复") : MUSE_UI_TEXT("YOUR WORDS", "你的话"));
        char info[96];
        snprintf(info, sizeof(info), "%d/%d · %s", page.role_page, page.role_pages,
                 muse_speech_busy() && muse_link_speech_follow_ready()
                    && muse_passport_reader_following() ? "跟随" : "手动");
        set_text(s_page_info, info);
        set_text(s_footer, link != MUSE_LINK_ONLINE ? "连接手机后翻页"
                 : page.truncated ? "完整内容请查看手机" : "上下翻页 · 长按下设置");
    } else {
        set_text(s_footer, link == MUSE_LINK_UNPAIRED || link == MUSE_LINK_PAIRING
                 ? ble.name : "长按下键打开设置");
    }
}

esp_err_t muse_ui_start(void)
{
    lv_indev_t *touch = NULL;
    if (!muse_board->display_start(&touch)) return ESP_FAIL;
    if (!muse_board->display_lock(-1)) return ESP_FAIL;
    /* The CJK bitmap font stays in flash; the writable descriptor adds an
     * ASCII/symbol fallback without modifying the font's const data. */
    s_text_font = passport_font_16;
    s_text_font.fallback = &lv_font_montserrat_16;
    lv_obj_t *screen = lv_screen_active();
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    s_status = label(screen, &s_text_font, 20, 16, 155, 22);
    s_power = label(screen, &lv_font_montserrat_14, 179, 16, 43, 22);
    s_face = lv_image_create(screen);
    s_page_info = label(screen, &s_text_font, 76, 63, 144, 22);
    lv_obj_add_flag(s_page_info, LV_OBJ_FLAG_HIDDEN);
    s_reply = label(screen, &s_text_font, 20, 108, 200, 161);
    /* Use the actual bitmap font metrics, not its nominal 16px size. */
    int lines = (161 + 2) / (lv_font_get_line_height(&s_text_font) + 2);
    muse_state_set_page(12, lines);
    s_footer = label(screen, &s_text_font, 20, 291, 200, 22);

    muse_menu_build(screen, muse_board->width, muse_board->height);
    s_pair = lv_obj_create(screen);
    lv_obj_remove_flag(s_pair, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(s_pair, 210, 140);
    lv_obj_center(s_pair);
    lv_obj_set_style_bg_color(s_pair, lv_color_hex(0x251d38), 0);
    lv_obj_set_style_bg_opa(s_pair, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(s_pair, 0, 0);
    s_pair_title = label(s_pair, &s_text_font, 12, 15, 185, 30);
    s_pair_detail = label(s_pair, &s_text_font, 12, 58, 185, 70);
    lv_obj_add_flag(s_pair, LV_OBJ_FLAG_HIDDEN);
    if (!lv_timer_create(frame, muse_board->frame_ms, NULL)) {
        muse_board->display_unlock();
        return ESP_ERR_NO_MEM;
    }
    s_ready = true;
    muse_board->display_unlock();
    ESP_LOGI(TAG, "portrait UI ready; %d text lines, ROM avatar frames", lines);
    return ESP_OK;
}

bool muse_ui_dark(void) { return s_dark; }
void muse_ui_show_face(void) { if (s_ready) muse_menu_close(); }
void muse_ui_set_swipe_enabled(bool enabled) { (void)enabled; }
void muse_ui_preview_brightness(int pct) { s_preview = pct; brightness(); }
bool muse_ui_image_size(int *w, int *h) { (void)w; (void)h; return false; }
bool muse_ui_image_draw(int x, int y, int w, int h, const uint16_t *pixels)
{
    (void)x; (void)y; (void)w; (void)h; (void)pixels;
    return false;
}
void muse_ui_image_hide(void) {}
void muse_ui_camera_hint(bool visible) { (void)visible; }
void muse_ui_request_snapshot(void)
{
    ESP_LOGW(TAG, "snapshots unavailable on Passport: no full-screen buffer");
}

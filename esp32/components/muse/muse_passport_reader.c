/* SPDX-License-Identifier: Apache-2.0 */
/* Full text stays in Android's bounded subscription cache. This independent
 * reader retains just one screen and does no radio work on the input, LVGL or
 * microphone task. Requests name the note; generation/revision checks prevent
 * an old turn or an earlier button press from replacing the current page. */
#include "muse_passport_reader.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cJSON.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "muse_link.h"

#define BODY_MAX 1536
#define POLL_US 2000000
#define TIMEOUT_US 6000000
#define REFRESH_US (180LL * 1000000)
static const char *TAG = "passport_reader";
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static struct {
    char note[80];
    char message[80];
    uint32_t offset;
    bool following;
    uint32_t generation, revision;
    int desired;
    int64_t refresh_until;
    muse_passport_page_t page;
    bool running;
} s_reader;
static struct {
    char body[BODY_MAX];
    size_t len;
    int status;
    uint32_t nonce;
    bool pending, done, overflow;
} s_rx;

static bool parse_snapshot(const char *body, muse_passport_page_t *page)
{
    cJSON *root = cJSON_Parse(body);
    bool ok = cJSON_IsTrue(cJSON_GetObjectItem(root, "ok"));
    const char *text = cJSON_GetStringValue(cJSON_GetObjectItem(root, "text"));
    const char *role = cJSON_GetStringValue(cJSON_GetObjectItem(root, "role"));
    const char *keys[] = {"page", "pages", "role_page", "role_pages"};
    int *values[] = {&page->page, &page->pages, &page->role_page, &page->role_pages};
    for (unsigned i = 0; i < 4; i++) {
        cJSON *value = cJSON_GetObjectItem(root, keys[i]);
        ok &= cJSON_IsNumber(value);
        *values[i] = cJSON_IsNumber(value) ? value->valueint : 0;
    }
    ok &= text && strlen(text) < sizeof(page->text) && role
       && (!strcmp(role, "user") || !strcmp(role, "assistant"))
       && page->pages >= 0 && page->pages < 20000 && page->page >= 0
       && (page->pages == 0 || page->page < page->pages)
       && page->role_pages >= 0 && page->role_pages <= page->pages
       && page->role_page >= 0 && page->role_page <= page->role_pages;
    if (ok) {
        strlcpy(page->text, text, sizeof(page->text));
        page->assistant = !strcmp(role, "assistant");
        page->truncated = cJSON_IsTrue(cJSON_GetObjectItem(root, "truncated"));
        page->ready = cJSON_IsTrue(cJSON_GetObjectItem(root, "ready"));
    }
    cJSON_Delete(root);
    return ok;
}

static void on_frame(void *ctx, int status, const uint8_t *data, size_t len, bool end)
{
    portENTER_CRITICAL(&s_lock);
    if ((uint32_t)(uintptr_t)ctx == s_rx.nonce && s_rx.pending && !s_rx.done) {
        if (status) s_rx.status = status;
        if (len >= sizeof(s_rx.body) - s_rx.len) s_rx.overflow = true;
        if (len && !s_rx.overflow) {
            memcpy(s_rx.body + s_rx.len, data, len);
            s_rx.len += len;
            s_rx.body[s_rx.len] = '\0';
        }
        s_rx.done = end || status < 0;
    }
    portEXIT_CRITICAL(&s_lock);
}

/* Percent-encode opaque message IDs; never insert them raw into a URL. */
static void encode_note(const char *note, char out[240])
{
    static const char hex[] = "0123456789ABCDEF";
    char *p = out;
    for (const unsigned char *n = (const unsigned char *)note; *n; n++) {
        if ((*n >= 'a' && *n <= 'z') || (*n >= 'A' && *n <= 'Z')
            || (*n >= '0' && *n <= '9') || *n == '-' || *n == '_' || *n == '.') *p++ = *n;
        else { *p++ = '%'; *p++ = hex[*n >> 4]; *p++ = hex[*n & 15]; }
    }
    *p = '\0';
}

static void reader_task(void *arg)
{
    (void)arg;
    int64_t stream = 0, next = 0, deadline = 0;
    uint32_t generation = 0, revision = 0;
    uint32_t queried_offset = UINT32_MAX;
    /* Only this task uses the snapshot; keep BLE/logging room in its 4 KiB stack. */
    static char body[BODY_MAX];
    unsigned stack_free = UINT32_MAX;
    for (;;) {
        char note[80];
        char message[80];
        uint32_t offset;
        int desired;
        uint32_t gen, rev;
        portENTER_CRITICAL(&s_lock);
        strlcpy(note, s_reader.note, sizeof(note));
        strlcpy(message, s_reader.following ? s_reader.message : "", sizeof(message));
        offset = s_reader.offset;
        desired = s_reader.desired;
        gen = s_reader.generation;
        rev = s_reader.revision;
        int64_t refresh_until = s_reader.refresh_until;
        bool done = s_rx.done;
        bool valid = s_rx.status == 200 && !s_rx.overflow;
        if (done) memcpy(body, s_rx.body, s_rx.len + 1);
        portEXIT_CRITICAL(&s_lock);
        int64_t now = esp_timer_get_time();
        if (stream && (gen != generation || rev != revision || !note[0] || done || now >= deadline)) {
            /* Stop callbacks before parsing/freeing the response. */
            portENTER_CRITICAL(&s_lock);
            s_rx.pending = false;
            portEXIT_CRITICAL(&s_lock);
            muse_link_req_cancel(stream);
            stream = 0;
            if (done && valid && gen == generation && rev == revision) {
                muse_passport_page_t page = {0};
                if (parse_snapshot(body, &page)) {
                    portENTER_CRITICAL(&s_lock);
                    if (gen == s_reader.generation && rev == s_reader.revision) s_reader.page = page;
                    portEXIT_CRITICAL(&s_lock);
                }
            }
            next = gen != generation || rev != revision ? 0 : now + POLL_US;
        }
        if (!stream && note[0] && !muse_state_asleep() && muse_link_req_ready()
            && ((now >= next && now < refresh_until) || gen != generation || rev != revision
                || (message[0] && offset != UINT32_MAX && offset != queried_offset))) {
            char encoded[240], path[640], encoded_message[240];
            int cols, lines;
            muse_state_page(&cols, &lines);
            encode_note(note, encoded);
            snprintf(path, sizeof(path), "/passport/reader?note=%s&page=%d&cols=%d&lines=%d", encoded, desired, cols, lines);
            if (message[0] && offset != UINT32_MAX) {
                encode_note(message, encoded_message);
                size_t n = strlen(path);
                snprintf(path + n, sizeof(path) - n, "&message=%s&offset=%lu", encoded_message, (unsigned long)offset);
            }
            generation = gen;
            revision = rev;
            queried_offset = offset;
            portENTER_CRITICAL(&s_lock);
            uint32_t nonce = ++s_rx.nonce;
            s_rx.len = 0;
            s_rx.body[0] = '\0';
            s_rx.status = 0;
            s_rx.done = s_rx.overflow = false;
            s_rx.pending = true;
            portEXIT_CRITICAL(&s_lock);
            stream = muse_link_req_open("GET", path, NULL, true, on_frame, (void *)(uintptr_t)nonce);
            deadline = esp_timer_get_time() + TIMEOUT_US;
            if (!stream) {
                portENTER_CRITICAL(&s_lock);
                s_rx.pending = false;
                portEXIT_CRITICAL(&s_lock);
                next = now + POLL_US;
            }
        }
        if (note[0]) {
            unsigned remaining = (unsigned)uxTaskGetStackHighWaterMark(NULL);
            if (remaining < stack_free) {
                stack_free = remaining;
                ESP_LOGI(TAG, "stack free=%u", remaining);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void muse_passport_reader_start(void)
{
    if (s_reader.running) return;
    /* The response snapshot is task-owned static storage. */
    s_reader.running = xTaskCreate(reader_task, "passport_reader", 4096, NULL, 2, NULL) == pdPASS;
    if (!s_reader.running) ESP_LOGE(TAG, "reader task allocation failed");
}

void muse_passport_reader_reset(void)
{
    portENTER_CRITICAL(&s_lock);
    s_reader.generation++;
    s_reader.revision++;
    s_reader.note[0] = '\0';
    s_reader.message[0] = '\0';
    s_reader.offset = UINT32_MAX;
    s_reader.following = true;
    memset(&s_reader.page, 0, sizeof(s_reader.page));
    s_reader.desired = -1; /* first transcript page; then first reply page */
    portEXIT_CRITICAL(&s_lock);
}

void muse_passport_reader_note(const char *identifier)
{
    portENTER_CRITICAL(&s_lock);
    strlcpy(s_reader.note, identifier, sizeof(s_reader.note));
    s_reader.generation++;
    s_reader.refresh_until = esp_timer_get_time() + REFRESH_US;
    portEXIT_CRITICAL(&s_lock);
}

void muse_passport_reader_step(int direction)
{
    portENTER_CRITICAL(&s_lock);
    s_reader.following = false;
    s_reader.revision++;
    if (s_reader.page.pages) {
        int at = s_reader.desired < 0 ? s_reader.page.page : s_reader.desired;
        at += direction;
        s_reader.desired = at < 0 ? 0 : at >= s_reader.page.pages ? s_reader.page.pages - 1 : at;
    }
    portEXIT_CRITICAL(&s_lock);
    muse_state_poke();
}

uint32_t muse_passport_reader_speech_begin(const char *note, const char *message)
{
    portENTER_CRITICAL(&s_lock);
    uint32_t generation = s_reader.generation;
    if (!strcmp(note, s_reader.note)) {
        strlcpy(s_reader.message, message, sizeof(s_reader.message));
        s_reader.offset = UINT32_MAX;
        s_reader.following = true;
        s_reader.desired = -1;
        s_reader.revision++;
        s_reader.refresh_until = esp_timer_get_time() + REFRESH_US;
    }
    portEXIT_CRITICAL(&s_lock);
    return generation;
}

void muse_passport_reader_speech_position(uint32_t generation, uint32_t offset)
{
    portENTER_CRITICAL(&s_lock);
    if (generation == s_reader.generation && s_reader.message[0]
        && offset != UINT32_MAX && s_reader.offset != offset) {
        s_reader.offset = offset;
        if (s_reader.following) {
            s_reader.desired = -1;
        }
        /* Finish the current query, then fetch the latest position. Cancelling
         * on every short sentence could prevent any response from arriving. */
        s_reader.refresh_until = esp_timer_get_time() + REFRESH_US;
    }
    portEXIT_CRITICAL(&s_lock);
}

bool muse_passport_reader_following(void)
{
    portENTER_CRITICAL(&s_lock);
    bool following = s_reader.following;
    portEXIT_CRITICAL(&s_lock);
    return following;
}

void muse_passport_reader_resume(void)
{
    portENTER_CRITICAL(&s_lock);
    s_reader.following = true;
    s_reader.desired = -1;
    s_reader.revision++;
    s_reader.refresh_until = esp_timer_get_time() + REFRESH_US;
    portEXIT_CRITICAL(&s_lock);
    muse_state_poke();
}

bool muse_passport_reader_page(muse_passport_page_t *out)
{
    portENTER_CRITICAL(&s_lock);
    bool available = s_reader.page.pages > 0;
    if (available) *out = s_reader.page;
    portEXIT_CRITICAL(&s_lock);
    return available;
}

#include "muse_speech.h"
#include "muse_speech_buffer.h"
#include "muse_link.h"
#include "muse_audio.h"
#include "muse_settings.h"
#include "muse_state.h"
#include "passport_opus.h"
#include "cJSON.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static SemaphoreHandle_t lock;
static muse_speech_buffer_t buffer;
static atomic_bool busy, stopped, started;
static uint32_t next_session;
static void put32(uint8_t *p, uint32_t n) { for (int i=0;i<4;i++) p[i]=n>>(8*i); }
/* state: 0 ready, 1 playing, 2 drained, 3 cancelled, 4 failed before
 * playback (may restart), 5 failed after playback (must not switch voice). */
static bool feedback(uint32_t id, uint32_t limit, unsigned state) {
    uint8_t data[9]; put32(data,id); put32(data+4,limit); data[8]=state;
    return muse_link_speech_send(15, data, sizeof(data));
}
static void play(void *arg) {
    uint32_t id=(uint32_t)(uintptr_t)arg;
    void *decoder=passport_opus_decoder_create();
    int16_t pcm[960];
    uint8_t packet[120];
    int64_t progress=esp_timer_get_time();
    bool failed=!decoder, ready=false, rejected=false;
    int64_t decode_peak=0;
    unsigned played_frames=0;
    while (!stopped && !failed && muse_link_req_ready() && muse_settings_speaker_on()) {
        unsigned count; bool ended, abort, terminal;
        uint32_t consumed;
        xSemaphoreTake(lock,portMAX_DELAY);
        count=buffer.count; ended=buffer.ended; abort=buffer.abort; terminal=buffer.terminal; consumed=buffer.consumed;
        if (abort) {
            buffer.count=0; buffer.rejected=true; buffer.abort=false;
        }
        xSemaphoreGive(lock);
        if (abort) {
            if (started || terminal) { failed=true; break; }
            if (!feedback(id,0,4)) { failed=true; break; }
            rejected=true; ready=false; progress=esp_timer_get_time();
        }
        xSemaphoreTake(lock,portMAX_DELAY);
        bool restart=rejected && !buffer.rejected;
        xSemaphoreGive(lock);
        if (restart) {
            passport_opus_decoder_destroy(decoder); decoder=passport_opus_decoder_create();
            failed=!decoder; rejected=false; progress=esp_timer_get_time();
            if (!feedback(id,MUSE_SPEECH_WINDOW,0)) failed=true;
            continue;
        }
        if (rejected) {
            if (esp_timer_get_time()-progress>30000000) { failed=true; break; }
            vTaskDelay(pdMS_TO_TICKS(10)); continue;
        }
        if (!ready && (count>=4 || ended)) ready=true;
        if (ready && ended && !count) break;
        size_t len=0;
        if (ready) {
            xSemaphoreTake(lock,portMAX_DELAY);
            len=muse_speech_buffer_take(&buffer,packet); consumed=buffer.consumed;
            xSemaphoreGive(lock);
        }
        if (len) {
            int64_t decode_at=esp_timer_get_time();
            int decoded=passport_opus_decode(decoder,packet,len,pcm);
            int64_t decode_us=esp_timer_get_time()-decode_at;
            if (decode_us>decode_peak) decode_peak=decode_us;
            if (decoded!=960) { failed=true; break; }
            for (unsigned off=0;off<960 && !stopped;off+=MUSE_AUDIO_CHUNK) {
                if (muse_audio_write(pcm+off,MUSE_AUDIO_CHUNK)!=ESP_OK) { failed=true; break; }
            }
            if (failed || stopped) break;
            /* Three writes exceed the 40 ms DMA capacity: samples have reached
             * playback before acknowledging STARTED, not merely the BLE FIFO. */
            bool first=!atomic_exchange(&started,true);
            played_frames++;
            xSemaphoreTake(lock,portMAX_DELAY); buffer.started=true; xSemaphoreGive(lock);
            muse_state_set_level(muse_audio_level(pcm,960));
            if (first || consumed%4==0) {
                if (!feedback(id,consumed+MUSE_SPEECH_WINDOW,1)) { failed=true; break; }
            }
            progress=esp_timer_get_time();
        } else {
            if (esp_timer_get_time()-progress>(started?30000000:60000000)) { failed=true; break; }
            /* Do not replay old DMA while a later sentence is synthesizing. */
            if (started) {
                static const int16_t silence[MUSE_AUDIO_CHUNK];
                if (muse_audio_write(silence,MUSE_AUDIO_CHUNK)!=ESP_OK) { failed=true; break; }
            } else vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
    /* Flush the final DMA tail, also silencing cancellation within <= 40 ms. */
    static const int16_t silence[MUSE_AUDIO_CHUNK];
    if (started) for (int i=0;i<3;i++) muse_audio_write(silence,MUSE_AUDIO_CHUNK);
    unsigned state=stopped || !muse_link_req_ready() || !muse_settings_speaker_on()?3:failed?5:2;
    feedback(id,0,state);
    passport_opus_decoder_destroy(decoder);
    ESP_LOGI("reply_speech","frames=%u decode_peak_us=%lld stack_free=%u heap_largest=%u state=%u",
        played_frames,(long long)decode_peak,(unsigned)uxTaskGetStackHighWaterMark(NULL),
        (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT),state);
    xSemaphoreTake(lock,portMAX_DELAY); buffer.session=0; xSemaphoreGive(lock);
    muse_state_set_level(0);
    if (state==5) {
        ESP_LOGW("reply_speech","speech stopped; text remains available");
        muse_state_set_caption("朗读失败，请阅读文字");
    }
    atomic_store(&busy,false);
    vTaskDelete(NULL);
}
void muse_speech_init(void) { lock=xSemaphoreCreateMutex(); }
bool muse_speech_busy(void) { return atomic_load(&busy); }
bool muse_speech_started(void) { return atomic_load(&busy) && atomic_load(&started); }
void muse_speech_stop(void) { atomic_store(&stopped,true); }
void muse_speech_reset(void) { if (!busy) atomic_store(&stopped,false); }
void muse_speech_receive(const uint8_t *data,size_t len) {
    if (!lock || !busy || stopped) return;
    xSemaphoreTake(lock,portMAX_DELAY); muse_speech_buffer_feed(&buffer,data,len); xSemaphoreGive(lock);
}
bool muse_speech_request(const char *note,const char *message) {
    if (busy) return false;
    if (stopped || !muse_settings_speaker_on() || !muse_link_speech_ready()) return true;
    if (!lock || next_session==UINT32_MAX) return true;
    uint32_t id=++next_session;
    cJSON *request=cJSON_CreateObject();
    if (!request) return true;
    cJSON_AddNumberToObject(request,"session",id);
    cJSON_AddNumberToObject(request,"limit",MUSE_SPEECH_WINDOW);
    cJSON_AddStringToObject(request,"note",note); cJSON_AddStringToObject(request,"message",message);
    char *body=cJSON_PrintUnformatted(request); cJSON_Delete(request);
    if (!body) return true;
    xSemaphoreTake(lock,portMAX_DELAY); muse_speech_buffer_begin(&buffer,id); xSemaphoreGive(lock);
    atomic_store(&started,false); atomic_store(&busy,true);
    /* A decoder's scratch stack and state exist only during a reply. */
    bool task_created=xTaskCreate(play,"reply_speech",24576,(void *)(uintptr_t)id,5,NULL)==pdPASS;
    bool ok=task_created && muse_link_speech_send(13,body,strlen(body));
    free(body);
    if (!ok) {
        atomic_store(&stopped,true);
        if (!task_created) atomic_store(&busy,false);
        muse_state_set_caption("朗读失败，请阅读文字");
    }
    return true;
}

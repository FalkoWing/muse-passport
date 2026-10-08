/* Android phone relay. Existing BLE passkey bonding protects device credentials.
 * Frames: type,u8 flags,u16 request,u16 sequence,u16 offset; little endian.
 * One acknowledged outgoing message at a time, maximum 8192 bytes. */
#include "phone_bridge.h"
#include "muse_adpcm.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "host/ble_hs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "cJSON.h"
#include "config_store.h"
#include "identity.h"
#include "sdk_token_store.h"
#include "esp_system.h"
#include "muse_settings.h"
#include "muse_state.h"
#include "esp_app_desc.h"
#include "esp_timer.h"
#include "esp_log.h"

#define MAX_MESSAGE 8192
#define HEADER 8
#define SLOTS 4
#define UUID(x) BLE_UUID128_INIT(0x00,0x79,0x6c,0x6c,0x6f,0x6a,0x00,0x80,0x00,0x40,x,0x00,0x65,0x73,0x75,0x4d)
enum { HELLO=1, CREDENTIALS, READY, OPEN, DATA, CANCEL, RESPONSE, ACK, TOKENS, ERROR,
       SDK_SETTINGS=12 };
static const ble_uuid128_t service_uuid=UUID(0x10), rx_uuid=UUID(0x11), tx_uuid=UUID(0x12);
static const char *TAG="phone_bridge";
static uint16_t tx_handle;
static atomic_int conn=BLE_HS_CONN_HANDLE_NONE;
static atomic_bool ready, subscribed;
static atomic_uint generation, waiting_ack;
static uint16_t sequence=1;
static uint32_t next_id=1;
static SemaphoreHandle_t tx_lock, ack_sem, slots_lock;
static QueueHandle_t messages, audio_messages;
#define AUDIO_FRAMES 320
#define AUDIO_BLOCK (9 + AUDIO_FRAMES / 2)
typedef struct {
    uint16_t id, len;
    uint32_t gen;
    bool end;
    char *control;
    uint8_t data[AUDIO_BLOCK];
} audio_message_t;
typedef struct { uint8_t type; uint16_t id, seq; size_t len; uint8_t *data; uint32_t gen; } message_t;
static message_t incoming;
typedef struct { uint16_t id; muse_link_req_cb cb; void *ctx; uint32_t gen; bool audio, ended; muse_adpcm_t codec; uint32_t audio_seq; } slot_t;
static slot_t slots[SLOTS];
static unsigned get16(const uint8_t *p) { return p[0] | (unsigned)p[1]<<8; }
static void put16(uint8_t *p,unsigned n) { p[0]=n; p[1]=n>>8; }
static bool secure(uint16_t handle) {
    struct ble_gap_conn_desc d;
    return handle!=BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_find(handle,&d)==0
        && d.sec_state.encrypted && d.sec_state.authenticated;
}
static void clear_incoming(void) { free(incoming.data); memset(&incoming,0,sizeof(incoming)); }

static bool notify_message(uint8_t type,uint16_t id,const void *body,size_t len,int wait_ms) {
    if (len>MAX_MESSAGE || !tx_lock || !subscribed || wait_ms<=0) return false;
    TickType_t timeout=pdMS_TO_TICKS(wait_ms);
    if (xSemaphoreTake(tx_lock,timeout)!=pdTRUE) return false;
    uint16_t handle=atomic_load(&conn);
    uint32_t gen=atomic_load(&generation);
    bool ok=secure(handle) && subscribed;
    unsigned chunk=ble_att_mtu(handle);
    chunk=chunk>247?247:chunk;
    chunk=chunk>HEADER+3?chunk-HEADER-3:12;
    uint16_t seq=sequence++;
    while (xSemaphoreTake(ack_sem,0)==pdTRUE) {}
    atomic_store(&waiting_ack,seq);
    int64_t deadline=esp_timer_get_time()+(int64_t)wait_ms*1000;
    const uint8_t *p=body;
    for (size_t off=0;ok;) {
        size_t n=len-off<chunk?len-off:chunk;
        uint8_t packet[244]; packet[0]=type; packet[1]=(off==0?1:0)|(off+n==len?2:0);
        put16(packet+2,id); put16(packet+4,seq); put16(packet+6,off);
        if (n) memcpy(packet+HEADER,p+off,n);
        for (;;) {
            if (gen!=atomic_load(&generation) || !subscribed || esp_timer_get_time()>deadline) { ok=false; break; }
            struct os_mbuf *om=ble_hs_mbuf_from_flat(packet,HEADER+n);
            int rc=om?ble_gatts_notify_custom(handle,tx_handle,om):BLE_HS_ENOMEM;
            if (rc==0) break;
            if (rc!=BLE_HS_ENOMEM && rc!=BLE_HS_EAGAIN) { ok=false; break; }
            vTaskDelay(pdMS_TO_TICKS(2));
        }
        off+=n;
        if (off==len) break;
    }
    int64_t left=deadline-esp_timer_get_time();
    if (ok) ok=left>0 && xSemaphoreTake(ack_sem,pdMS_TO_TICKS((left+999)/1000))==pdTRUE
        && gen==atomic_load(&generation) && secure(handle);
    atomic_store(&waiting_ack,0);
    xSemaphoreGive(tx_lock);
    return ok;
}
static void fail_requests(void) {
    slot_t old[SLOTS];
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    memcpy(old,slots,sizeof(old)); memset(slots,0,sizeof(slots));
    xSemaphoreGive(slots_lock);
    for (int i=0;i<SLOTS;i++) if (old[i].cb) old[i].cb(old[i].ctx,-1,NULL,0,true);
}
static void credential(cJSON *root,const char *key) {
    char *value=malloc(3072);
    if (value) {
        value[0]=0;
        config_get_str(key,value,3072);
        cJSON_AddStringToObject(root,key,value);
        memset(value,0,3072); free(value);
    }
}
static void credentials(void) {
    cJSON *root=cJSON_CreateObject();
    if (!root) return;
    credential(root,"access_token"); credential(root,"refresh_token");
    credential(root,"api_url_v2"); credential(root,"noise_host");
    cJSON_AddStringToObject(root,"node_id",identity_node_id());
    cJSON_AddStringToObject(root,"device_id",identity_device_id());
    cJSON_AddStringToObject(root,"version",esp_app_get_description()->version);
    cJSON_AddStringToObject(root,"sdk_token",identity_sdk_token()?identity_sdk_token():"");
    cJSON_AddBoolToObject(root,"sdk_settings",true);
    cJSON_AddBoolToObject(root,"sdk_token_configured",identity_sdk_token()!=NULL);
    char vm[MUSE_VM_MAX+1]; muse_settings_hatch_vm(vm);
    cJSON_AddStringToObject(root,"vm_id",vm);
    char *json=cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (json) { notify_message(CREDENTIALS,0,json,strlen(json),10000); memset(json,0,strlen(json)); free(json); }
}
static void save_tokens(const uint8_t *data,size_t len) {
    cJSON *root=cJSON_ParseWithLength((const char *)data,len);
    const char *access=cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root,"access_token"));
    const char *refresh=cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root,"refresh_token"));
    // Refresh first: if power fails before the access write, the next phone
    // can refresh the stale access using the already committed new refresh.
    bool ok=access && refresh && access[0] && refresh[0] && strlen(access)<3072 && strlen(refresh)<3072
        && config_set_str("refresh_token",refresh) && config_set_str("access_token",access);
    cJSON_Delete(root);
    const char *reply=ok?"{\"ok\":true}":"{\"ok\":false}";
    notify_message(TOKENS,0,reply,strlen(reply),10000);
}
static void dispatch_response(const message_t *m) {
    if (m->len<3) return;
    int status=(int16_t)get16(m->data);
    bool end=m->data[2]!=0;
    slot_t chosen={0};
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    for (int i=0;i<SLOTS;i++) if (slots[i].id==m->id && slots[i].gen==m->gen) {
        chosen=slots[i]; if (end || status<0) memset(&slots[i],0,sizeof(slots[i])); break;
    }
    xSemaphoreGive(slots_lock);
    if (chosen.cb) chosen.cb(chosen.ctx,status,m->data+3,m->len-3,end || status<0);
}
static void sdk_settings(const message_t *m) {
    cJSON *root=m->len && m->len<=192?cJSON_ParseWithLength((const char *)m->data,m->len):NULL;
    const char *action=cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root,"action"));
    const char *token=cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root,"token"));
    bool restart=false, ok=false, configured=identity_sdk_token()!=NULL;
    if (action && !strcmp(action,"get")) ok=true;
    else if (action && (!strcmp(action,"clear") || (!strcmp(action,"set") && sdk_token_store_valid(token)))) {
        bool clear=!strcmp(action,"clear");
        ok=sdk_token_store_save(clear?"":token);
        restart=ok;
        if (ok) configured=!clear;
    }
    // Neither success nor failure ever echoes the secret.
    char reply[100];
    int n=snprintf(reply,sizeof(reply),"{\"ok\":%s,\"configured\":%s,\"restart\":%s}",
        ok?"true":"false",configured?"true":"false",restart?"true":"false");
    if (root) {
        cJSON *secret=cJSON_GetObjectItemCaseSensitive(root,"token");
        if (cJSON_IsString(secret)) memset(secret->valuestring,0,strlen(secret->valuestring));
        cJSON_Delete(root);
    }
    // Commit/readback precedes acknowledgement; reboot also recovers a lost ACK.
    notify_message(SDK_SETTINGS,m->id,reply,n,3000);
    if (restart) {
        memset(m->data,0,m->len);
        vTaskDelay(pdMS_TO_TICKS(250));
        esp_restart();
    }
}
static void worker(void *arg) {
    (void)arg;
    message_t m;
    for (;;) {
        if (xQueueReceive(messages,&m,pdMS_TO_TICKS(250))==pdTRUE) {
            if (m.gen==atomic_load(&generation) && secure(atomic_load(&conn))) {
                switch (m.type) {
                    case HELLO: credentials(); break;
                    case READY:
                        atomic_store(&ready,true); muse_state_poke();
                        ESP_LOGI(TAG,"Muse ready through Android BLE"); break;
                    case RESPONSE: dispatch_response(&m); break;
                    case TOKENS: save_tokens(m.data,m.len); break;
                    case SDK_SETTINGS: sdk_settings(&m); break;
                    case ERROR:
                        atomic_store(&ready,false); fail_requests(); muse_state_poke(); break;
                    default: break;
                }
            }
            if (m.data) { memset(m.data,0,m.len); free(m.data); }
        }
        // GAP never calls user callbacks; request cleanup belongs on this task.
        if (!atomic_load(&ready)) fail_requests();
    }
}
static int access(uint16_t handle,uint16_t attr,struct ble_gatt_access_ctxt *ctxt,void *arg) {
    (void)attr; (void)arg;
    if (!secure(handle)) return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    if (ctxt->op!=BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_READ_NOT_PERMITTED;
    uint8_t b[244]; uint16_t n;
    if (ble_hs_mbuf_to_flat(ctxt->om,b,sizeof(b),&n)!=0 || n<HEADER || (b[1]&~3)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    uint8_t type=b[0],flags=b[1]; unsigned id=get16(b+2),seq=get16(b+4),off=get16(b+6);
    if (type==ACK) {
        if (flags!=3 || off || n!=HEADER) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        if (id==atomic_load(&waiting_ack)) xSemaphoreGive(ack_sem);
        return 0;
    }
    if (type!=HELLO && type!=READY && type!=RESPONSE && type!=TOKENS && type!=ERROR && type!=SDK_SETTINGS) return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
    if (flags&1) {
        if (incoming.data || off) { clear_incoming(); return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN; }
        incoming=(message_t){.type=type,.id=id,.seq=seq,.gen=atomic_load(&generation)};
        // Allocate even for empty messages so overlapping starts are detected.
        incoming.data=malloc(1);
        if (!incoming.data) return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    size_t bytes=n-HEADER;
    if (!incoming.data || incoming.type!=type || incoming.id!=id || incoming.seq!=seq || off!=incoming.len
        || off+bytes>(type==SDK_SETTINGS?192:MAX_MESSAGE)) { clear_incoming(); return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN; }
    if (bytes) {
        uint8_t *grown=realloc(incoming.data,incoming.len+bytes);
        if (!grown) { clear_incoming(); return BLE_ATT_ERR_INSUFFICIENT_RES; }
        incoming.data=grown; memcpy(grown+incoming.len,b+HEADER,bytes); incoming.len+=bytes;
    }
    if (flags&2) {
        if (!messages || xQueueSend(messages,&incoming,0)!=pdTRUE) { clear_incoming(); return BLE_ATT_ERR_INSUFFICIENT_RES; }
        memset(&incoming,0,sizeof(incoming));
    }
    return 0;
}
static const struct ble_gatt_svc_def services[]={
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&service_uuid.u,.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=&rx_uuid.u,.access_cb=access,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC|BLE_GATT_CHR_F_WRITE_AUTHEN},
        {.uuid=&tx_uuid.u,.access_cb=access,.val_handle=&tx_handle,.flags=BLE_GATT_CHR_F_NOTIFY},
        {0}}}, {0}};
const struct ble_gatt_svc_def *phone_bridge_services(void) { return services; }
/* Separate consumer: radio flow control must never stop I2S capture. Batch
 * four 20 ms blocks; the 48-block queue covers pre-roll and short radio stalls.
 * On overflow the whole turn fails, rather than silently removing samples. */
static bool active_audio(const audio_message_t *m) {
    bool valid=false;
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    for (int i=0;i<SLOTS;i++) if (slots[i].id==m->id && slots[i].gen==m->gen && slots[i].audio) valid=true;
    xSemaphoreGive(slots_lock);
    return valid && m->gen==atomic_load(&generation) && phone_bridge_ready();
}
static void audio_failed(const audio_message_t *m) {
    slot_t failed={0};
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    for (int i=0;i<SLOTS;i++) if (slots[i].id==m->id && slots[i].gen==m->gen) failed=slots[i];
    xSemaphoreGive(slots_lock);
    phone_bridge_cancel(m->id);
    if (failed.cb) failed.cb(failed.ctx,-1,NULL,0,true);
}
static void audio_worker(void *arg) {
    (void)arg;
    audio_message_t m, pending={0};
    bool have=false;
    uint8_t packet[1 + AUDIO_BLOCK * 8];
    for (;;) {
        if (have) { m=pending; have=false; }
        else if (xQueueReceive(audio_messages,&m,portMAX_DELAY)!=pdTRUE) continue;
        if (!active_audio(&m)) { free(m.control); continue; }
        if (m.control) {
            bool ok=notify_message(OPEN,m.id,m.control,strlen(m.control),3000);
            free(m.control);
            if (!ok) audio_failed(&m);
            continue;
        }
        unsigned count=1;
        size_t len=m.len;
        memcpy(packet+1,m.data,m.len);
        bool end=m.end;
        while (!end && count<8) {
            audio_message_t next;
            /* Wait for up to four blocks, then drain an existing backlog. */
            if (xQueueReceive(audio_messages,&next,count<4?pdMS_TO_TICKS(25):0)!=pdTRUE) break;
            if (next.control || next.id!=m.id || next.gen!=m.gen) { pending=next; have=true; break; }
            memcpy(packet+1+len,next.data,next.len); len+=next.len;
            end=next.end; count++;
        }
        packet[0]=end;
        if (active_audio(&m) && !notify_message(DATA,m.id,packet,len+1,3000)) {
            ESP_LOGW(TAG,"audio transmission failed; cancelling turn");
            audio_failed(&m);
        }
    }
}
void phone_bridge_init(void) {
    tx_lock=xSemaphoreCreateMutex(); ack_sem=xSemaphoreCreateBinary(); slots_lock=xSemaphoreCreateMutex();
    messages=xQueueCreate(4,sizeof(message_t));
    audio_messages=xQueueCreate(48,sizeof(audio_message_t));
    if (!tx_lock || !ack_sem || !slots_lock || !messages || !audio_messages || xTaskCreate(audio_worker,"phone_audio",4096,NULL,4,NULL)!=pdPASS || xTaskCreate(worker,"phone_bridge",4096,NULL,4,NULL)!=pdPASS) abort();
}
int phone_bridge_gap_event(struct ble_gap_event *e) {
    switch (e->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (!e->connect.status) { atomic_store(&conn,e->connect.conn_handle); atomic_fetch_add(&generation,1); }
            break;
        case BLE_GAP_EVENT_DISCONNECT:
            atomic_store(&conn,BLE_HS_CONN_HANDLE_NONE); atomic_store(&ready,false); atomic_store(&subscribed,false);
            atomic_fetch_add(&generation,1); clear_incoming(); xSemaphoreGive(ack_sem); muse_state_poke(); break;
        case BLE_GAP_EVENT_ENC_CHANGE:
            if (e->enc_change.status || !secure(e->enc_change.conn_handle)) atomic_store(&ready,false);
            break;
        case BLE_GAP_EVENT_SUBSCRIBE:
            if (e->subscribe.attr_handle==tx_handle) {
                atomic_store(&subscribed,e->subscribe.cur_notify!=0);
                if (!e->subscribe.cur_notify) atomic_store(&ready,false);
                else {
                    // At 30 ms, a phone taking one packet per event cannot keep up with audio.
                    // Request 15 ms and a supervision timeout within Apple's accessory guidelines.
                    struct ble_gap_upd_params params={.itvl_min=12,.itvl_max=12,.latency=0,.supervision_timeout=600};
                    ble_gap_update_params(e->subscribe.conn_handle,&params);
                }
            }
            break;
        default: break;
    }
    return 0;
}
bool phone_bridge_ready(void) { return atomic_load(&ready) && atomic_load(&subscribed); }
int64_t phone_bridge_open(const char *verb,const char *path,const char *const *headers,bool end_body,muse_link_req_cb cb,void *ctx) {
    if (!phone_bridge_ready() || !cb) return 0;
    slot_t *slot=NULL; uint16_t id=0;
    bool audio_request=!strcmp(verb,"POST") && !strcmp(path,"/chat/stream") && !end_body;
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    // IDs are not reused within one boot, avoiding delayed-response aliasing.
    if (next_id<=65535) for (int i=0;i<SLOTS;i++) if (!slots[i].id) { slot=&slots[i]; break; }
    if (slot) {
        id=next_id++;
        *slot=(slot_t){.id=id,.cb=cb,.ctx=ctx,.gen=atomic_load(&generation),
            .audio=audio_request};
    }
    xSemaphoreGive(slots_lock);
    if (!id) return 0;
    cJSON *root=cJSON_CreateObject(), *h=cJSON_CreateArray();
    cJSON_AddStringToObject(root,"verb",verb); cJSON_AddStringToObject(root,"path",path);
    cJSON_AddBoolToObject(root,"end",end_body);
    if (audio_request) cJSON_AddStringToObject(root,"audio","ima-adpcm-16000-v1");
    for (int i=0;headers && headers[i] && headers[i+1];i+=2) {
        cJSON *pair=cJSON_CreateArray(); cJSON_AddItemToArray(pair,cJSON_CreateString(headers[i]));
        cJSON_AddItemToArray(pair,cJSON_CreateString(headers[i+1])); cJSON_AddItemToArray(h,pair);
    }
    cJSON_AddItemToObject(root,"headers",h);
    char *json=cJSON_PrintUnformatted(root); cJSON_Delete(root);
    bool ok=false;
    if (json && audio_request) {
        // The OPEN and subsequent samples share one FIFO. Starting a recording
        // cannot block I2S while BLE waits for the phone to acknowledge OPEN.
        audio_message_t m={.id=id,.gen=atomic_load(&generation),.control=json};
        ok=xQueueSend(audio_messages,&m,0)==pdTRUE;
        if (!ok) free(json);
    } else {
        ok=json && notify_message(OPEN,id,json,strlen(json),10000);
        free(json);
    }
    if (!ok) { phone_bridge_cancel(id); return 0; }
    return id;
}
bool phone_bridge_send(int64_t id,const void *data,size_t len,bool end_body,int wait_ms) {
    if (!phone_bridge_ready() || id<1 || id>65535 || len>MAX_MESSAGE-1) return false;
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    slot_t *audio=NULL;
    bool found=false;
    for (int i=0;i<SLOTS;i++) if (slots[i].id==id) {
        found=true; if (slots[i].audio) audio=&slots[i];
    }
    if (audio) {
        bool ok=!audio->ended && !(len%4);
        const int16_t *pcm=data;
        size_t frames=len/2;
        while (ok && (frames || end_body)) {
            size_t n=frames>AUDIO_FRAMES?AUDIO_FRAMES:frames;
            audio_message_t m={.id=id,.gen=audio->gen,.len=n?9+n/2:0,.end=end_body && n==frames};
            if (n) {
                put16(m.data,audio->codec.pred); m.data[2]=audio->codec.index;
                put16(m.data+3,n);
                uint32_t seq=audio->audio_seq++;
                for (int k=0;k<4;k++) m.data[5+k]=seq>>(8*k);
                muse_adpcm_encode_block(&audio->codec,pcm,n,m.data+9);
                pcm+=n; frames-=n;
            }
            ok=xQueueSend(audio_messages,&m,0)==pdTRUE;
            if (!frames) break;
        }
        if (end_body || !ok) audio->ended=true;
        xSemaphoreGive(slots_lock);
        return ok;
    }
    xSemaphoreGive(slots_lock);
    if (!found) return false;
    uint8_t *b=malloc(len+1); if (!b) return false;
    b[0]=end_body; if (len) memcpy(b+1,data,len);
    bool ok=notify_message(DATA,id,b,len+1,wait_ms); free(b); return ok;
}
void phone_bridge_cancel(int64_t id) {
    bool found=false;
    xSemaphoreTake(slots_lock,portMAX_DELAY);
    for (int i=0;i<SLOTS;i++) if (slots[i].id==id) { memset(&slots[i],0,sizeof(slots[i])); found=true; }
    xSemaphoreGive(slots_lock);
    if (found && phone_bridge_ready()) notify_message(CANCEL,id,NULL,0,1000);
}

"""Real cache + reader task + speech play; deterministic BLE, I2S and scheduling fakes."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MUSE = ROOT / 'esp32/components/muse'
sys.path.insert(0, str(ROOT / 'android/app/src/main/python'))
from reply_cache import ReplyCache


class SpeechFollowTest(unittest.TestCase):
    def test_real_playback_drives_reader_and_manual_control(self):
        cache = ReplyCache(); cache.begin(); cache.note('note')
        for role, message, text in [('user','note','我的问题'),('assistant','reply','一'*84+'二'*84+'三'*84+'四'*84)]:
            cache.feed((json.dumps({'type':'event','event':'message.'+role,'payload':{'message_id':message,'reply_to_message_id':'note','display_text':text}},ensure_ascii=False)+'\n').encode())
        pages = [cache.reader_page(f'/passport/reader?note=note&page={n}&cols=12&lines=7').decode() for n in range(5)]
        reader = re.sub(r'^#include .*$', '', (MUSE / 'muse_passport_reader.c').read_text(), flags=re.M)
        speech = (MUSE / 'muse_speech.c').read_text()
        play = speech[speech.index('static void play('):speech.index('void muse_speech_init')]

        fakes = r'''

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <setjmp.h>
#include "cJSON.h"
#include "muse_speech_buffer.h"
#define MUSE_CAPTION_MAX 400
#define MUSE_AUDIO_CHUNK 320
#define MUSE_MODE_LISTENING 2
#define MUSE_MODE_OFF 6
#define ESP_OK 0
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(p) ((void)(p))
#define portEXIT_CRITICAL(p) ((void)(p))
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(ms) (ms)
#define pdPASS 1
typedef int portMUX_TYPE;
typedef struct {char text[MUSE_CAPTION_MAX];int page,pages,role_page,role_pages;bool assistant,truncated,ready;} muse_passport_page_t;
static int64_t now;
static unsigned requests,reader_ticks;
static jmp_buf reader_return;
static bool running_reader;
static int64_t esp_timer_get_time(void){return now;}
static void reader_tick(void);
static void vTaskDelay(int ticks){now+=(int64_t)ticks*1000;if(running_reader){reader_ticks++;reader_tick();if(reader_ticks>=50)longjmp(reader_return,1);}}
static int xTaskCreate(void(*fn)(void*),const char *name,int stack,void *arg,int priority,void *handle){return 1;}
static bool muse_link_req_ready(void){return true;}
static bool muse_state_asleep(void){return false;}
static void muse_state_page(int *cols,int *lines){*cols=12;*lines=7;}
static void muse_state_poke(void){}
static unsigned uxTaskGetStackHighWaterMark(void *task){return 2048;}
static void muse_link_req_cancel(int64_t id);
#undef strlcpy
#define strlcpy repro_strlcpy
static size_t repro_strlcpy(char *dst,const char *src,size_t cap){size_t n=strlen(src);if(cap){size_t k=n<cap-1?n:cap-1;memcpy(dst,src,k);dst[k]=0;}return n;}
'''
        bridge = r'''

static const char *cached_pages[5];
static bool delayed;
static void (*pending_cb)(void*,int,const uint8_t*,size_t,bool);
static void *pending_ctx;
static const char *pending_body;
static unsigned pending_tick;
static void muse_link_req_cancel(int64_t id){pending_cb=NULL;}
static int64_t muse_link_req_open(const char *verb,const char *path,void *headers,bool end,
 void(*cb)(void*,int,const uint8_t*,size_t,bool),void *ctx){
 int selected=atoi(strstr(path,"page=")+5);
 const char *offset=strstr(path,"offset=");
 if(offset)selected=1+atoi(offset+7)/84;
 if(selected<0)selected=1;
 assert(selected<5);requests++;
 const char *body=cached_pages[selected];
 if(delayed){pending_cb=cb;pending_ctx=ctx;pending_body=body;pending_tick=reader_ticks+4;}
 else cb(ctx,200,(const uint8_t*)body,strlen(body),true);
 return requests;
}
'''
        speech_fakes = r'''

static int lock;
static uint32_t reader_generation;
static muse_speech_buffer_t buffer;
static atomic_bool busy,stopped,started;
static unsigned produced,decoded,writes,played_states,terminal_state;
static void push_frames(void){
 while(buffer.count<MUSE_SPEECH_WINDOW && produced<120){
  uint8_t frame[133]={7,0,0,0};frame[8]=5;
  unsigned origin=(produced/40)*84;for(unsigned i=0;i<4;i++)frame[9+i]=origin>>(8*i);for(unsigned i=0;i<4;i++)frame[4+i]=produced>>(8*i);
  assert(muse_speech_buffer_feed(&buffer,frame,sizeof(frame)));produced++;
 }
 if(produced==120 && !buffer.ended){
  uint8_t end[9]={7,0,0,0,120,0,0,0,1};assert(muse_speech_buffer_feed(&buffer,end,sizeof(end)));
 }
}
static bool feedback(uint32_t id,uint32_t limit,unsigned state){
 assert(id==7);if(state==1){played_states++;push_frames();}if(state>=2)terminal_state=state;return true;
}
static bool muse_settings_speaker_on(void){return true;}
static void *passport_opus_decoder_create(void){return &lock;}
static void passport_opus_decoder_destroy(void *p){}
static int passport_opus_decode(void *d,const uint8_t *p,size_t len,int16_t *pcm){decoded++;memset(pcm,0,1920);return 960;}
static int muse_audio_write(const int16_t *pcm,unsigned len){writes++;now+=(int64_t)len*1000000/16000;return ESP_OK;}
static unsigned muse_audio_level(const int16_t *pcm,unsigned len){return 0;}
static void muse_state_set_level(unsigned level){}
static void muse_state_set_caption(const char *caption){}
static void xSemaphoreTake(int lock,int timeout){}
static void xSemaphoreGive(int lock){}
static void vTaskDelete(void *task){}
'''
        main = r'''

static void poll_reader(void){reader_ticks=0;running_reader=true;if(!setjmp(reader_return))reader_task(NULL);running_reader=false;}
static void reader_tick(void){
 if(!delayed)return;
 // A new sentence starts faster than a page response can arrive.
 muse_passport_reader_speech_position(reader_generation,reader_ticks%2 ? 168 : 84);
 if(pending_cb && reader_ticks>=pending_tick){
  void (*cb)(void*,int,const uint8_t*,size_t,bool)=pending_cb;pending_cb=NULL;
  cb(pending_ctx,200,(const uint8_t*)pending_body,strlen(pending_body),true);
 }
 if(reader_ticks==5)assert(s_reader.page.role_page==2);
}
int main(int argc,char **argv){
 assert(argc==6);for(int i=0;i<5;i++)cached_pages[i]=argv[i+1];
 muse_passport_reader_reset();muse_passport_reader_note("note");poll_reader();
 assert(s_reader.page.role_page==1);
 reader_generation=muse_passport_reader_speech_begin("note","reply");
 muse_speech_buffer_begin(&buffer,7);busy=true;push_frames();
 poll_reader();assert(s_reader.page.role_page==1); // BLE receipt alone cannot turn a page.
 play((void*)(uintptr_t)7);
 assert(decoded==120 && terminal_state==2 && played_states>0);
 poll_reader();assert(s_reader.page.role_page==3);
 muse_passport_reader_step(-1);poll_reader();assert(s_reader.page.role_page==2 && !muse_passport_reader_following());
 muse_passport_reader_speech_position(reader_generation,252);poll_reader();assert(s_reader.page.role_page==2);
 muse_passport_reader_resume();poll_reader();assert(s_reader.page.role_page==4 && muse_passport_reader_following());
 muse_passport_reader_step(-1);poll_reader();assert(s_reader.page.role_page==3);
 muse_passport_reader_speech_begin("note","reply");assert(muse_passport_reader_following());
 muse_passport_reader_speech_position(reader_generation,0);poll_reader();assert(s_reader.page.role_page==1);
 unsigned before=requests;
 muse_passport_reader_speech_position(reader_generation,84);delayed=true;poll_reader();delayed=false;
 assert(requests-before<=13); // Queries finish instead of being cancelled on each sentence.
 muse_passport_reader_reset();muse_passport_reader_note("next");
 muse_passport_reader_speech_position(reader_generation,168);assert(s_reader.offset==UINT32_MAX && !s_reader.message[0]);
 puts("Actual playback advanced pages; receipt, manual pause, resume and stale-turn isolation passed");
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / 'follow.c'; exe = Path(tmp) / 'follow'
            c.write_text(fakes + bridge + reader + speech_fakes + play + main)
            cjson = ROOT / 'esp32/managed_components/espressif__cjson/cJSON'
            # Leave room in the 4 KiB task for BLE notification and logging.
            # Measure the task itself without compiler-dependent fake inlining.
            # Match firmware's stack-check mode; Ubuntu defaults add a canary
            # and prevent reuse of otherwise non-overlapping local buffers.
            obj = Path(tmp) / 'follow.o'
            subprocess.run(['cc','-std=gnu11','-O2','-fno-inline','-fno-stack-protector','-fstack-usage','-I',str(cjson),'-I',str(MUSE),'-c',str(c),'-o',str(obj)],check=True,capture_output=True,timeout=30)
            usage = obj.with_suffix('.su').read_text().splitlines()
            reader_frames = [int(line.split('\t')[1]) for line in usage
                             if line.split('\t')[0].rsplit(':', 1)[-1].split('.', 1)[0] == 'reader_task']
            self.assertEqual(len(reader_frames), 1, usage)
            self.assertLessEqual(reader_frames[0], 1792, 'reader task leaves too little stack for BLE/logging')
            subprocess.run(['cc','-std=gnu11','-O0','-fsanitize=address,undefined','-I',str(cjson),'-I',str(MUSE),str(c),str(cjson/'cJSON.c'),str(MUSE/'muse_speech_buffer.c'),'-o',str(exe)],check=True,capture_output=True,timeout=30)
            result = subprocess.run([str(exe),*pages],capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)

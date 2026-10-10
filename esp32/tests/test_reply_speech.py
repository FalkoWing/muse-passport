from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReplySpeechTest(unittest.TestCase):
    def run_c(self, source, extra=()):
        with tempfile.TemporaryDirectory() as directory:
            c = Path(directory) / 'test.c'
            exe = Path(directory) / 'test'
            c.write_text(source)
            subprocess.run(['cc', '-std=gnu11', '-fsanitize=address,undefined', '-g',
                            '-I', str(ROOT / 'components/muse'), str(c), *map(str, extra), '-o', str(exe)],
                           check=True, capture_output=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_bounded_frames_cancel_fallback_and_slow_link(self):
        self.run_c(r'''
#include "muse_speech_buffer.h"
#include <assert.h>
#include <string.h>
static unsigned char p[129], out[120];
static void number(unsigned char *p, unsigned n){for(int i=0;i<4;i++)p[i]=n>>(8*i);}
static bool feed(muse_speech_buffer_t *b,unsigned id,unsigned frame,unsigned kind){
 number(p,id);number(p+4,frame);p[8]=kind;
 return muse_speech_buffer_feed(b,p,kind?9:129);
}
int main(void){
 muse_speech_buffer_t b;
 muse_speech_buffer_begin(&b,7);
 assert(!feed(&b,6,0,0) && !b.abort && b.count==0);
 for(unsigned i=0;i<8;i++)assert(feed(&b,7,i,0));
 assert(b.count==8 && !feed(&b,7,8,0) && b.terminal);
 muse_speech_buffer_begin(&b,8);
 assert(feed(&b,8,0,0));assert(!feed(&b,8,0,0) && b.abort);
 muse_speech_buffer_begin(&b,9);
 assert(feed(&b,9,0,0));assert(feed(&b,9,0,2));
 assert(!muse_speech_buffer_take(&b,out));
 b.count=0;b.rejected=true;b.abort=false;
 assert(!feed(&b,9,1,0));assert(feed(&b,9,0,3));
 assert(b.received==0 && b.consumed==0 && !b.rejected);
 assert(feed(&b,9,0,0));b.started=true;b.rejected=true;
 assert(!feed(&b,9,0,3));
 muse_speech_buffer_begin(&b,10);
 assert(feed(&b,10,0,0));assert(feed(&b,10,1,1));
 assert(muse_speech_buffer_take(&b,out)==120 && b.count==0 && b.ended);
 assert(!feed(&b,10,1,0));
 muse_speech_buffer_begin(&b,11);
 assert(feed(&b,11,0,4) && b.terminal && b.abort);
 // 120 s: one aggregate transport packet per 30 ms event. Credit status
 // and its ACK each consume an event; foreground synthesis is pre-generated.
 // This proves queue/packet budget, not a Bluetooth or I2S device result.
 muse_speech_buffer_begin(&b,12);
 unsigned sent=0,limit=8,played=0,next_play=0,controls=0;bool playing=false;
 for(unsigned ms=0;played<2000 && ms<125000;ms+=30){
   if(controls)controls--;
   else if(sent<limit && sent<2000){assert(feed(&b,12,sent,0));sent++;}
   if(!playing && b.count>=4){playing=true;next_play=ms+60;}
   if(playing && ms>=next_play){
     assert(muse_speech_buffer_take(&b,out)==120);played++;next_play+=60;
     if(played==1 || played%4==0){limit=played+8;controls+=2;}
   }
   assert(b.count<=8);
 }
 assert(played==2000 && sent==2000 && !b.abort);
 // Malformed/stale fuzz input never escapes the bounded receiver.
 for(unsigned i=0;i<10000;i++){
   muse_speech_buffer_begin(&b,i+20);
   for(unsigned j=0;j<129;j++)p[j]=(i*31+j*17)&255;
   muse_speech_buffer_feed(&b,p,i%130);
   assert(b.count<=8);
 }
}
''', [ROOT / 'components/muse/muse_speech_buffer.c'])

    def test_zero_frame_end_releases_playback_without_audio(self):
        source = (ROOT / 'components/muse/muse_speech.c').read_text()
        play = source[source.index('static void play('):source.index('void muse_speech_init')]
        self.run_c(r'''
#include "muse_speech_buffer.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(ms) (ms)
#define MUSE_AUDIO_CHUNK 320
#define ESP_OK 0
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
static int lock;
static uint32_t reader_generation;
static void muse_passport_reader_speech_position(uint32_t generation,uint32_t offset){}
static muse_speech_buffer_t buffer;
static atomic_bool busy,stopped,started;
static unsigned decoded,written,deleted,states,last_state;
static int64_t now;
static bool feedback(uint32_t id,uint32_t limit,unsigned state){assert(id==7 && limit==0);states++;last_state=state;return true;}
static bool muse_link_req_ready(void){return true;}
static bool muse_settings_speaker_on(void){return true;}
static void *passport_opus_decoder_create(void){return &lock;}
static void passport_opus_decoder_destroy(void *p){(void)p;}
static int passport_opus_decode(void *d,const uint8_t *p,size_t len,int16_t *out){decoded++;return 960;}
static int muse_audio_write(const int16_t *p,unsigned len){written++;return ESP_OK;}
static unsigned muse_audio_level(const int16_t *p,unsigned len){return 0;}
static void muse_state_set_level(unsigned level){}
static void muse_state_set_caption(const char *caption){}
static int64_t esp_timer_get_time(void){return now+=100000;}
static void xSemaphoreTake(int lock,int timeout){}
static void xSemaphoreGive(int lock){}
static void vTaskDelay(int ticks){}
static void vTaskDelete(void *task){deleted++;}
''' + play + r'''
int main(void){
 muse_speech_buffer_begin(&buffer,7);busy=true;
 // Existing session + frame zero + END, without any Opus payload.
 uint8_t end[9]={7,0,0,0,0,0,0,0,1};
 assert(muse_speech_buffer_feed(&buffer,end,sizeof(end)));
 play((void *)(uintptr_t)7);
 assert(states==1 && last_state==2 && !busy && !started && buffer.session==0);
 assert(decoded==0 && written==0 && deleted==1);
}
''', [ROOT / 'components/muse/muse_speech_buffer.c'])

    def test_ok_short_stop_hold_record_and_menu_priority(self):
        source = (ROOT / 'components/muse/muse_input.c').read_text()
        handler = source[source.index('static void talk_button'):source.index('/* A pairing prompt')]
        self.run_c(r'''
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>
#define CONFIG_MUSE_PHONE_BRIDGE 1
#define MUSE_BTN_TALK_PRESS 1
#define MUSE_BTN_TALK_RELEASE 2
#define MUSE_PTT_DOWN 1
#define MUSE_PTT_UP 2
#define MUSE_MENU_SELECT 1
#define pdMS_TO_TICKS(ms) (ms)
typedef unsigned TickType_t;
static bool s_talk_down, busy, menu, asleep, pairing;
static unsigned ticks, downs, ups, stops, selects;
static struct {const char *talk_button;} board={"OK"};
static const typeof(board) *muse_board=&board;
static TickType_t xTaskGetTickCount(void){return ticks;}
static bool muse_speech_busy(void){return busy;}
static void muse_speech_stop(void){busy=false;stops++;}
static bool muse_menu_is_open(void){return menu;}
static bool muse_state_asleep(void){return asleep;}
static bool muse_link_talk_press(void){return pairing;}
static void muse_state_poke(void){}
static void set_asleep(bool b,const char *s){(void)s;asleep=b;}
static void post(int type,bool wake){(void)wake;if(type==1)downs++;else ups++;}
static void muse_menu_key(int key){(void)key;selects++;}
''' + handler + r'''
int main(void){
 busy=true;talk_button(1);ticks=100;talk_button(2);
 assert(stops==1 && downs==0 && ups==0 && !s_talk_down);
 busy=true;ticks=1000;talk_button(1);ticks=1349;talk_button(0);assert(downs==0);
 ticks=1350;talk_button(0);assert(downs==1 && s_talk_down);talk_button(2);assert(ups==1);
 busy=true;menu=true;talk_button(1);talk_button(2);assert(selects==1 && stops==2);
 menu=false;busy=true;talk_button(3);assert(stops==3 && downs==1);
 busy=false;talk_button(1);assert(downs==2);talk_button(2);assert(ups==2);
}
''')

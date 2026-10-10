"""Real history scanner and turn pump: explicit busy, ordinary timeout and hard cap."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BusyWaitTest(unittest.TestCase):
    def test_server_busy_extends_only_reply_wait_with_a_hard_cap(self):
        source = (ROOT / 'components/muse/muse_chat_link.c').read_text()
        row = source[source.index('/* The one row of a history page. */'):source.index('enum { RX_NOTE')]
        scanner = source[source.index('/* ---- History pages, read in place ---- */'):source.index('/* A page in one frame')]
        pump = source[source.index('static void pump(void)'):source.index('/* ---- Public ---- */')]
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define TEXT_MAX 1024
#define EV_TEXT 200
#define REPLY_TIMEOUT_US 60000000LL
#define SETTLE_US 6000000LL
#define CONFIG_MUSE_PHONE_BRIDGE 1
#define ESP_LOGI(...) ((void)0)
#define MUSE_UI_TEXT(a,b) (b)
#define MUSE_HATCH_EV_DONE 1
#define RX_NOTE 0
#define RX_ROW 1
#include "muse_text.h"
''' + row + scanner + r'''
enum {T_IDLE,T_TALKING,T_ACK,T_REPLY};
static struct {int phase;int64_t t_end,t_reply,t_poll;bool speech_active,replied,skipped_big,agent_busy;char text[20];} s_turn;
static int64_t s_stream[2],now;
static unsigned failed,completed;
static int64_t esp_timer_get_time(void){return now;}
static bool muse_speech_busy(void){return false;}
static bool received(int slot){return false;}
static void on_ack(void){}
static void on_page(void){}
static bool poll_row(void){return true;}
static void fail(const char *why){failed++;s_turn.phase=T_IDLE;}
static bool scroll(int64_t time){return true;}
static void end_turn(void){completed++;s_turn.phase=T_IDLE;}
static void emit(int event,void *data){}
''' + pump + r'''
static void run(int phase,bool busy,int seconds,bool timeout){
 s_turn.phase=phase;s_turn.agent_busy=busy;s_turn.t_end=0;
 now=(int64_t)seconds*1000000;unsigned before=failed;pump();assert((failed>before)==timeout);
}
int main(void){
 row_t row;
 const char *busy="{\"ok\":true,\"result\":{\"chat_events\":[],\"agent_busy\":true}}";
 const char *idle="{\"result\":{\"agent_busy\":false,\"chat_events\":[]}}";
 const char *legacy="{\"result\":{\"chat_events\":[]}}";
 assert(parse_page(busy,strlen(busy),&row) && row.agent_busy);
 assert(parse_page(idle,strlen(idle),&row) && !row.agent_busy);
 assert(parse_page(legacy,strlen(legacy),&row) && !row.agent_busy);
 run(T_REPLY,false,59,false);run(T_REPLY,false,61,true);
 run(T_REPLY,true,61,false);run(T_REPLY,true,179,false);run(T_REPLY,true,181,true);
 run(T_REPLY,false,120,true); // idle/complete stops the extension.
 run(T_ACK,true,61,true); // Agent work never extends the upload acknowledgement.
 s_turn.replied=true;s_turn.t_reply=0;
 unsigned before=completed;
 run(T_REPLY,true,120,false);assert(completed==before);
 run(T_REPLY,false,120,false);assert(completed==before+1);
 run(T_REPLY,true,181,false);assert(completed==before+2);
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / 'busy.c'; exe = Path(tmp) / 'busy'; c.write_text(harness)
            compiled = subprocess.run(['cc','-std=gnu11','-fsanitize=address,undefined','-include',str(ROOT/'tests/host_compat.h'),'-I',str(ROOT/'components/muse'),str(c),str(ROOT/'components/muse/muse_text.c'),'-o',str(exe)],capture_output=True,text=True,timeout=30)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            ran = subprocess.run([str(exe)],capture_output=True,text=True,timeout=15)
            self.assertEqual(ran.returncode,0,ran.stderr)

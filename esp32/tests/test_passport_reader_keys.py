"""Production DOWN handler: paging, menu hold and wake must not overlap."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReaderKeysTest(unittest.TestCase):
    def test_short_press_hold_wake_and_recording(self):
        source = (ROOT / 'components/muse/muse_input.c').read_text()
        handler = source[source.index('static void menu_button'):source.index('static void aux_key')]
        harness = '''#include <stdbool.h>
#include <stdint.h>
#include <assert.h>
#define CONFIG_MUSE_PHONE_BRIDGE 1
#define pdMS_TO_TICKS(ms) (ms)
#define MUSE_MENU_DOWN 1
typedef uint32_t TickType_t;
static struct {const char *aux_button;} board={"DOWN"};
static const typeof(board) *muse_board=&board;
static bool s_talk_down, asleep, menu;
static unsigned ticks;static int steps, opens;
static TickType_t xTaskGetTickCount(void){return ticks;}
static bool muse_state_asleep(void){return asleep;}
static bool muse_menu_is_open(void){return menu;}
static void muse_state_poke(void){}
static void muse_passport_reader_step(int direction){steps+=direction;}
static void muse_menu_key(int key){(void)key;opens++;menu=true;}
static void set_asleep(bool value,const char *why){(void)why;asleep=value;}
''' + handler + '''
int main(void){
 menu_button(true,true);ticks=300;menu_button(true,false);menu_button(false,true);
 assert(steps==1 && opens==0);
 ticks=1000;menu_button(true,true);ticks=1800;menu_button(true,false);
 ticks=1900;menu_button(true,false);menu_button(false,true);
 assert(steps==1 && opens==1 && menu);
 menu_button(true,true);menu_button(false,true);assert(opens==2 && steps==1);
 menu=false;asleep=true;menu_button(true,true);menu_button(false,true);
 assert(!asleep && steps==1 && opens==2);
 s_talk_down=true;menu_button(true,true);ticks+=1000;menu_button(true,false);menu_button(false,true);
 assert(steps==1 && opens==2);
 s_talk_down=false;menu_button(true,true);menu_button(false,true);
 assert(opens==2 && steps==2);
 // Same long-hold behavior at idle, even when the reader has no page.
 menu_button(true,true);ticks+=800;menu_button(true,false);menu_button(false,true);
 assert(opens==3 && steps==2);return 0;}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / 'keys.c'; c.write_text(harness)
            binary = Path(tmp) / 'keys'
            result = subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

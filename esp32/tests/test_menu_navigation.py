"""Execute real menu dispatch: visible-item wrapping and destructive OK only."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MenuNavigationTest(unittest.TestCase):
    def test_up_wrap_details_and_confirmation(self):
        source = (ROOT / 'components/muse/muse_menu.c').read_text()
        dispatch = source[source.index('static void handle('):source.index('void muse_menu_key(')]
        harness = '''#include <assert.h>
#include <stdbool.h>
#define MUSE_UI_TEXT(a,b) (b)
typedef enum {MUSE_MENU_DOWN,MUSE_MENU_SELECT,MUSE_MENU_UP} muse_menu_key_t;
typedef enum {VIEW_CLOSED,VIEW_LIST,VIEW_STATUS,VIEW_BATTERY,VIEW_POWER,VIEW_RESET} view_t;
#define ITEM_COUNT 6
static view_t s_view;
static int s_sel, activated=-1, reset, power, closed;
static void *s_rows[ITEM_COUNT]={ (void*)1,(void*)1,0,0,(void*)1,(void*)1 };
static void refresh(void){}
static void show(view_t view){s_view=view;}
static void open_menu(void){s_view=VIEW_LIST;}
static void activate(int item){activated=item;}
static void muse_menu_close(void){s_view=VIEW_CLOSED;closed++;}
static void muse_input_request_power_off(void){power++;}
static void muse_state_set_caption(const char *text){(void)text;}
static void muse_link_reset_setup(void){reset++;}
''' + dispatch + '''
int main(void){
 handle(MUSE_MENU_UP);assert(s_view==VIEW_CLOSED);
 handle(MUSE_MENU_DOWN);assert(s_view==VIEW_LIST);
 handle(MUSE_MENU_UP);assert(s_sel==5 && activated==-1);
 handle(MUSE_MENU_DOWN);assert(s_sel==0);
 handle(MUSE_MENU_DOWN);handle(MUSE_MENU_DOWN);assert(s_sel==4);
 handle(MUSE_MENU_UP);assert(s_sel==1);
 handle(MUSE_MENU_SELECT);assert(activated==1);
 s_view=VIEW_STATUS;handle(MUSE_MENU_UP);assert(s_view==VIEW_LIST);
 s_view=VIEW_BATTERY;handle(MUSE_MENU_UP);assert(s_view==VIEW_LIST);
 for(int key=0;key<3;key++){
  s_view=VIEW_RESET;handle(key);assert(reset==(key==1?1:key==2?1:0));
  s_view=VIEW_POWER;handle(key);assert(power==(key==1?1:key==2?1:0));
 }
 assert(reset==1 && power==1 && closed==2);
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / 'menu.c'; c.write_text(harness)
            exe = Path(tmp) / 'menu'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(exe)], check=True, capture_output=True, timeout=30)
            subprocess.run([str(exe)], check=True, capture_output=True, timeout=10)

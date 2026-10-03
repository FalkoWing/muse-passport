"""Real Muse self-parent reply, through Python cache and production C parser."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from reply_cache import ReplyCache

ROOT=Path(__file__).resolve().parents[2]

class FirmwareReplyTest(unittest.TestCase):
    def test_real_delta_reply_survives_phone_cache_and_firmware_parser(self):
        cache=ReplyCache();cache.begin();cache.note('voice-note')
        cache.feed(json.dumps({'type':'event','event':'delta.message_done','payload':{
            'message_id':'assistant-msg','reply_to_message_id':'assistant-msg',
            'display_text':'你好，已经收到你的消息。'}},ensure_ascii=False).encode()+b'\n')
        page=cache.page('/chat/history?after_seq=1')
        source=(ROOT/'esp32/components/muse/muse_chat_link.c').read_text()
        row=source[source.index('typedef struct {',source.index('/* The one row')):source.index('enum { RX_NOTE')]
        parser=source[source.index('typedef struct {',source.index('/* ---- History pages')):source.index('/* A page in one frame')]
        harness='''#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define TEXT_MAX 1024
'''+row+parser+'''
int main(void) {
 char input[12288];size_t n=fread(input,1,sizeof(input),stdin);row_t r;
 if(!parse_page(input,n,&r))return 1;
 if(!r.found || !r.ready || strcmp(r.event,"message.assistant"))return 2;
 if(strcmp(r.reply_to,"voice-note"))return 3;
 fwrite(r.text,1,strlen(r.text),stdout);return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c=Path(tmp)/'reply.c';c.write_text(harness);binary=Path(tmp)/'reply'
            result=subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],input=page,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.decode(),'你好，已经收到你的消息。')

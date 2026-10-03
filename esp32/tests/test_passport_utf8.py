"""Compile the production JSON string scanner and test every output boundary."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PassportUtf8Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory()
        source=(ROOT/'components/muse/muse_chat_link.c').read_text()
        scanner=source[source.index('static int hex4('):source.index('/* Steps over one value:')]
        c=Path(cls.tmp.name)/'scanner.c'
        c.write_text('#include <stdint.h>\n#include <stdbool.h>\n#include <stdlib.h>\n#include <string.h>\n#include <stdio.h>\ntypedef struct {const char *p,*end;} scan_t;\n'+scanner+'''
#include "muse_text.h"
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    char text[1024]={0};size_t cap=strtoul(argv[2],NULL,10);
    if(cap>sizeof(text))return 3;
    if(!strcmp(argv[1],"trim")) {
        size_t n=fread(text,1,cap?cap-1:0,stdin);
        text[n]=0;muse_text_trim_utf8(text);
    } else {
        char json[8192];size_t n=fread(json,1,sizeof(json),stdin);
        scan_t s={json,json+n};if(!read_string(&s,text,cap))return 4;
    }
    fwrite(text,1,strlen(text),stdout);return 0;
}
''')
        cls.binary=Path(cls.tmp.name)/'scanner'
        subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-Wall','-Wextra','-Werror',
            '-include',str(ROOT/'tests/host_compat.h'),'-I',str(ROOT/'components/muse'),str(c),
            str(ROOT/'components/muse/muse_text.c'),'-o',str(cls.binary)],check=True,capture_output=True)

    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()

    def test_raw_and_escaped_unicode_keep_whole_prefix(self):
        text='中文😀é多一句话，完整显示 ABC'
        for escaped in (False,True):
            for cap in range(1,len(text.encode())+3):
                result=subprocess.run([str(self.binary),'scan',str(cap)],input=json.dumps(text,ensure_ascii=escaped).encode(),capture_output=True,check=True)
                decoded=result.stdout.decode('utf8')
                self.assertTrue(text.startswith(decoded),(cap,decoded))
                self.assertLess(len(result.stdout),cap)

    def test_format_truncation_removes_partial_codepoint(self):
        text='中文😀é多一句话 ABC'
        for cap in range(1,len(text.encode())+2):
            result=subprocess.run([str(self.binary),'trim',str(cap)],input=text.encode(),capture_output=True,check=True)
            self.assertTrue(text.startswith(result.stdout.decode('utf8')))

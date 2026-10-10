"""Real streaming WAV/base64 helpers against independent standard encodings."""
import base64
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VoiceEncodingTest(unittest.TestCase):
    def test_wav_and_base64_boundaries(self):
        source = (ROOT / 'components/muse/muse_chat_text.c').read_text()
        helpers = source[source.index('static void put_le'):source.index('/* Last CAPTION_CHARS')]
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / 'encoding.c'
            c.write_text('''#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define MUSE_HATCH_WAV_HEADER 44
''' + helpers + '''
int main(int argc,char **argv){
 unsigned char bytes[8192];char encoded[10924];
 if(argc>1){unsigned rate;sscanf(argv[1],"%u",&rate);muse_hatch_wav_header(bytes,rate);fwrite(bytes,1,44,stdout);}
 else {size_t n=fread(bytes,1,sizeof(bytes),stdin);size_t m=muse_hatch_base64(bytes,n,encoded);fwrite(encoded,1,m,stdout);}
 return 0;}
''')
            exe = Path(tmp) / 'encoding'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', str(c), '-o', str(exe)], check=True, capture_output=True, timeout=30)
            for rate in (16000, 24000, 48000):
                expected = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 0xffffffff, b'WAVE', b'fmt ', 16, 1, 1, rate, rate * 2, 2, 16, b'data', 0xffffffff)
                self.assertEqual(subprocess.check_output([str(exe), str(rate)], timeout=10), expected)
            for n in (0, 1, 2, 3, 44, 1492, 1535, 1536, 1537, 8192):
                pcm = bytes((i * 37 + 11) % 256 for i in range(n))
                self.assertEqual(subprocess.check_output([str(exe)], input=pcm, timeout=10), base64.b64encode(pcm))

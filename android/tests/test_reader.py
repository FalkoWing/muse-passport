"""Complete transcripts and long replies through the local BLE reader."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import urlencode
from reply_cache import ReplyCache, TEXT_LIMIT, wrap_pages

ROOT = Path(__file__).resolve().parents[2]


def read(cache, page=-1, note='note'):
    return json.loads(cache.reader_page('/passport/reader?' + urlencode({'note': note, 'page': page})))


class ReaderTest(unittest.TestCase):
    def setUp(self):
        self.cache = ReplyCache()
        self.cache.begin()
        self.cache.note('note')

    def test_whole_transcript_then_reply_and_backwards(self):
        transcript = '第一句话。第二句话。第三句话。' * 30
        self.cache._row('note', 'message.user', transcript + '\n[file:audio/wav attachment]', True, '')
        first = read(self.cache)
        self.assertEqual(first['role'], 'user')
        self.assertGreater(first['pages'], 1)
        self.assertTrue(first['text'].startswith('第一句话'))
        whole = ''.join(read(self.cache, p)['text'].replace('\n', '') for p in range(first['pages']))
        self.assertEqual(whole, transcript)
        self.cache._row('reply', 'message.assistant', '回复内容' * 80, True, 'reply')
        answer = read(self.cache)
        self.assertEqual(answer['role'], 'assistant')
        self.assertEqual(answer['role_page'], 1)
        self.assertEqual(read(self.cache, answer['page'] - 1)['role'], 'user')
        self.assertEqual(read(self.cache, 999999)['page'], answer['pages'] - 1)

    def test_long_reply_not_limited_by_history_or_c_caption_buffer(self):
        text = '这是中文完整长回复。' * 1500  # > 8 KB, > 1 KB
        self.cache._row('r', 'message.assistant', text, True, 'note')
        first = read(self.cache)
        self.assertGreater(first['pages'], 100)
        whole = ''.join(read(self.cache, p)['text'].replace('\n', '') for p in range(first['pages']))
        self.assertEqual(whole, text)
        for page in wrap_pages(text):
            self.assertLess(len(page.encode()), 400)
            self.assertLessEqual(len(page.splitlines()), 6)
            self.assertTrue(all(len(line) <= 12 for line in page.splitlines()))

    def test_transcript_update_after_history_cursor_advanced(self):
        self.assertEqual(read(self.cache)['pages'], 0)
        self.cache.page('/chat/history?after_seq=0')  # placeholder consumed
        self.cache._row('note', 'message.user', '完整的稍后转录', True, '')
        self.assertEqual(read(self.cache)['text'], '完整的稍后转录')

    def test_boundaries_empty_paragraphs_and_four_byte_characters(self):
        text = '😀' * 150 + '\n\n' + '中文' * 50
        pages = wrap_pages(text)
        self.assertEqual(''.join(pages).replace('\n', ''), text.replace('\n', ''))
        self.assertTrue(all(len(p.encode()) < 400 for p in pages))
        self.assertEqual(wrap_pages('ab\n\ncd', 12, 6), ['ab\n\ncd'])
        self.assertEqual(wrap_pages(''), [])
        self.assertEqual(wrap_pages('x' * 72), ['\n'.join(['x' * 12] * 6)])

    def test_new_turn_and_unrelated_reply_never_leak_into_reader(self):
        self.cache._row('other', 'message.assistant', '另一个对话', True, 'someone-else')
        self.assertEqual(read(self.cache)['pages'], 0)
        self.cache._row('r', 'message.assistant', '本轮回复', True, 'note')
        self.cache.begin()
        self.cache.note('new-note')
        self.assertFalse(read(self.cache)['ok'])
        self.assertEqual(read(self.cache, note='new-note')['pages'], 0)

    def test_long_deltas_and_explicit_overflow_notice(self):
        for n in range(200):
            self.cache.feed(json.dumps({'type': 'event', 'event': 'delta.text_append',
                'payload': {'message_id': 'r', 'text': '中文' * 100}}, ensure_ascii=False).encode() + b'\n')
        self.cache.feed(b'{"type":"event","event":"delta.message_done","payload":{"message_id":"r"}}\n')
        page = read(self.cache)
        self.assertTrue(page['truncated'])
        self.assertLessEqual(len(self.cache.rows['r']['reader_text'].encode()), TEXT_LIMIT)
        self.assertGreater(len(self.cache.rows['r']['reader_text'].encode()), 8000)
        self.assertEqual(len(self.cache.rows['r']['display_text'].encode()), 7998)

    def test_phone_history_preview_stays_small_without_losing_reader(self):
        self.cache._row('r', 'message.assistant', '中文' * 2000, True, 'note')
        data = self.cache.page('/chat/history?after_seq=1&caption=1')
        self.assertLess(len(data), 1100)
        row = json.loads(data)['result']['chat_events'][0]
        self.assertNotIn('reader_text', row)
        self.assertNotIn('truncated', row)
        self.assertGreater(read(self.cache)['pages'], 1)

    def test_production_firmware_parser_accepts_all_pages_and_rejects_bad_metadata(self):
        source = (ROOT / 'esp32/components/muse/muse_passport_reader.c').read_text()
        parser = source[source.index('static bool parse_snapshot'):source.index('static void on_frame')]
        cjson_dir = ROOT / 'esp32/managed_components/espressif__cjson/cJSON'
        if not cjson_dir.exists():
            self.fail('Build ESP-IDF once before parser integration tests')
        harness = '''#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "cJSON.h"
#define MUSE_CAPTION_MAX 400
#undef strlcpy
#define strlcpy(dst,src,n) snprintf(dst,n,"%s",src)
typedef struct {char text[400];int page,pages,role_page,role_pages;bool assistant,truncated,ready;} muse_passport_page_t;
''' + parser + '''
int main(void) {char body[1600];size_t n=fread(body,1,1599,stdin);body[n]=0;
muse_passport_page_t page={0};if(!parse_snapshot(body,&page))return 2;
fwrite(page.text,1,strlen(page.text),stdout);return 0;}
'''
        self.cache._row('r', 'message.assistant', '完整回复。' * 80, True, 'note')
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / 'reader.c'; c.write_text(harness)
            binary = Path(tmp) / 'reader'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(cjson_dir),
                            str(c), str(cjson_dir / 'cJSON.c'), '-o', str(binary)], check=True, capture_output=True)
            for p in range(read(self.cache)['pages']):
                data = self.cache.reader_page('/passport/reader?note=note&page=' + str(p))
                result = subprocess.run([str(binary)], input=data, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.decode(), json.loads(data)['text'])
            for data in (b'{', b'{"ok":false}', b'{"ok":true}',
                         json.dumps(dict(read(self.cache), page=99999)).encode(),
                         json.dumps(dict(read(self.cache), text='x' * 400)).encode()):
                self.assertNotEqual(subprocess.run([str(binary)], input=data, capture_output=True).returncode, 0)

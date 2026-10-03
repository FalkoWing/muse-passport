import json
import unittest
from reply_cache import ReplyCache


def event(name, **payload):
    return json.dumps({"type": "event", "event": name, "payload": payload}, ensure_ascii=False).encode() + b'\n'


class ReplyCacheTest(unittest.TestCase):
    def test_chunked_unicode_delta_and_completion(self):
        c = ReplyCache(); c.begin(); c.note('note')
        data = event('delta.message_start', message_id='reply', reply_to_message_id='note')
        data += event('delta.text_append', message_id='reply', text='你好，')
        data += event('delta.text_append', message_id='reply', text='Passport')
        data += event('delta.message_done', message_id='reply')
        for offset in range(0, len(data), 7):
            c.feed(data[offset:offset+7])
        row = json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'][0]
        self.assertEqual(row['display_text'], '你好，Passport')
        self.assertTrue(row['display_text_ready'])
        self.assertEqual(row['reply_to_message_id'], 'note')

    def test_mark_is_before_ack_race(self):
        c = ReplyCache(); c.begin(); c.note('note')
        self.assertEqual(json.loads(c.page('/chat/history?limit=1'))['result']['chat_events'], [])
        self.assertEqual(json.loads(c.page('/chat/history?after_seq=0'))['result']['chat_events'][0]['message_id'], 'note')

    def test_other_chat_reply_not_displayed(self):
        c = ReplyCache(); c.begin(); c.note('note')
        c.feed(event('message.assistant', message_id='other', reply_to_message_id='another-note', display_text='private other reply'))
        self.assertEqual(json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'], [])

    def test_memory_limits(self):
        c = ReplyCache()
        for n in range(100):
            c.feed(event('message.user', message_id=str(n), display_text='x'*9000))
        self.assertEqual(len(c.rows), 32)
        self.assertLessEqual(max(len(r['display_text']) for r in c.rows.values()), 8000)
        with self.assertRaises(ValueError):
            c.feed(b'x'*(1024*1024+1))


if __name__ == '__main__':
    unittest.main()

class ReplyAssociationTest(unittest.TestCase):
    def test_ack_second_id_and_assistant_chain(self):
        c=ReplyCache();c.begin();c.note('uploaded-note','thread-parent')
        c.feed(event('message.assistant',message_id='first',reply_to_message_id='thread-parent',display_text='第一条回复'))
        c.feed(event('message.assistant',message_id='second',parent_message_id='first',display_text='继续回复'))
        first=json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'][0]
        self.assertEqual(first['display_text'],'第一条回复')
        self.assertEqual(first['reply_to_message_id'],'uploaded-note')
        second=json.loads(c.page('/chat/history?after_seq=2'))['result']['chat_events'][0]
        self.assertEqual(second['display_text'],'继续回复')
        self.assertEqual(second['reply_to_message_id'],'uploaded-note')

    def test_completion_cannot_be_reversed_by_pending_snapshot(self):
        c=ReplyCache();c.begin();c.note('note')
        c.feed(event('delta.text_append',message_id='r',text='中文回复',reply_to_message_id='note'))
        c.feed(event('delta.message_done',message_id='r'))
        c.feed(event('message.assistant',message_id='r',display_text_ready=False))
        row=json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'][0]
        self.assertTrue(row['display_text_ready'])
        self.assertEqual(row['display_text'],'中文回复')

    def test_chinese_text_limit_is_bytes_and_valid_utf8(self):
        c=ReplyCache();c.feed(event('message.assistant',message_id='r',display_text='中文😀'*4000))
        text=c.rows['r']['display_text']
        self.assertLessEqual(len(text.encode()),8000)
        self.assertTrue(('中文😀'*4000).startswith(text))

class RealMuseAssociationTest(unittest.TestCase):
    def test_self_referential_assistant_ids_from_real_muse_delta(self):
        c=ReplyCache();c.begin();c.note('uploaded-note')
        # Regression for the actual Muse stream observed on Pixel: the
        # assistant points at itself, not at the upload ACK's message ID.
        c.feed(event('message.user',message_id='uploaded-note',display_text='你好，请回复一句中文'))
        c.feed(event('delta.message_start',message_id='assistant-msg-real',reply_to_message_id='assistant-msg-real'))
        c.feed(event('delta.text_append',message_id='assistant-msg-real',text='你好，已经收到你的消息。'))
        c.feed(event('delta.message_done',message_id='assistant-msg-real',reply_to_message_id='assistant-msg-real'))
        row=json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'][0]
        self.assertEqual(row['event_name'],'message.assistant')
        self.assertEqual(row['reply_to_message_id'],'uploaded-note')
        self.assertEqual(row['display_text'],'你好，已经收到你的消息。')
        self.assertTrue(row['display_text_ready'])

    def test_self_id_at_completion_preserves_explicit_parent(self):
        c=ReplyCache();c.begin();c.note('note')
        c.feed(event('delta.message_start',message_id='r',reply_to_message_id='note'))
        c.feed(event('delta.text_append',message_id='r',text='中文回复'))
        c.feed(event('delta.message_done',message_id='r',reply_to_message_id='r'))
        self.assertEqual(c.rows['r']['reply_to_message_id'],'note')
        self.assertTrue(json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'])

    def test_self_id_does_not_erase_explicit_other_turn_parent(self):
        c=ReplyCache();c.begin();c.note('note')
        c.feed(event('delta.message_start',message_id='other',reply_to_message_id='someone-else'))
        c.feed(event('delta.message_done',message_id='other',reply_to_message_id='other',display_text='其他对话'))
        self.assertEqual(c.rows['other']['reply_to_message_id'],'someone-else')
        self.assertFalse(json.loads(c.page('/chat/history?after_seq=1'))['result']['chat_events'])

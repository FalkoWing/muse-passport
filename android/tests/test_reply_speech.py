import json
import unittest
from reply_cache import ReplyCache


class SpeechCacheTest(unittest.TestCase):
    def test_completed_full_text_isolated_by_note_and_parent(self):
        cache = ReplyCache()
        cache.begin()
        cache.note('note')
        def feed(event, **payload):
            cache.feed((json.dumps(dict(type='event', event=event, payload=payload))+'\n').encode())
        text = '自然清楚的声音。' * 1500
        feed('delta.text_append', message_id='reply', parent_message_id='note', text=text)
        self.assertIsNone(cache.speech_text('note', 'reply'))
        feed('delta.message_done', message_id='reply', parent_message_id='note')
        self.assertEqual(cache.speech_text('note', 'reply'), text)
        feed('message.assistant', message_id='other', parent_message_id='someone', content='另一轮')
        self.assertIsNone(cache.speech_text('note', 'other'))
        self.assertIsNone(cache.speech_text('old', 'reply'))
        cache.begin()
        cache.note('next')
        self.assertIsNone(cache.speech_text('note', 'reply'))

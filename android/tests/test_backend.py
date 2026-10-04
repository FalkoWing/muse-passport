import base64
import json
import queue
import struct
import threading
import time
import unittest
from passport_bridge import (Bridge, CREDENTIALS, READY, OPEN, DATA, CANCEL, RESPONSE, TOKENS,
                             ERROR, connection_failure, MuseConnectionError)
from musegadget.link_client import MessageDecoder, encode_message
from musegadget.noise.noise_xx import NoiseXXResponder
from musegadget.noise.framing import NoiseFrameDecoder, encode_noise_frames
from musegadget.noise.envelope import (
    decode_service_request, decode_service_frame, ServiceFrame, ApplicationResponse,
    BodyChunk, encode_service_response, ServiceResponse, encode_service_frame,
)


class Channel:
    """Real official Noise responder; a fake Muse VM, not a fake cipher."""
    def __init__(self):
        self.queue = queue.Queue()
        self.phase = 0
        self.responder = NoiseXXResponder()
        self.responder.initialize()
        self.decoder = NoiseFrameDecoder()
        self.control = MessageDecoder()
        self.requests = {}
        self.uploads = []
        self.closed = False
        self.subscription = None

    def reply(self, frame):
        body = encode_service_response(ServiceResponse(payload=encode_service_frame(frame)))
        for plain in encode_noise_frames(body):
            self.queue.put(self.tx.encrypt_with_ad(b"", plain))

    def send(self, raw):
        if self.phase == 0:
            self.queue.put(self.responder.read_message1_and_write_message2(bytes(raw)))
            self.phase = 1
            return
        if self.phase == 1:
            self.responder.read_message3(bytes(raw))
            self.tx, self.rx = self.responder.split()
            self.phase = 2
            return
        envelope = self.decoder.decode(self.rx.decrypt_with_ad(b"", bytes(raw)))
        if envelope is None:
            return
        frame = decode_service_frame(decode_service_request(envelope).payload)
        if frame.kind == "request":
            self.requests[frame.stream_id] = [frame.value.path, bytearray(frame.value.body)]
            if frame.value.path == "/link-control":
                self.reply(ServiceFrame.response(frame.stream_id, ApplicationResponse(status=200, end_body=False)))
            elif frame.value.end_body:
                self.complete(frame.stream_id)
        elif frame.kind == "body_chunk":
            path, body = self.requests[frame.stream_id]
            if path == "/link-control":
                for message in self.control.feed(frame.value.data):
                    if message.get("method") == "link.register":
                        assert message["params"]["platform"] == "esp32"
                        self.reply(ServiceFrame.body_chunk(frame.stream_id,
                            BodyChunk(data=encode_message({"id": message["id"], "result": {"ok": True}}))))
            else:
                body.extend(frame.value.data)
                if frame.value.end_body:
                    self.complete(frame.stream_id)

    def complete(self, identifier):
        path, body = self.requests[identifier]
        if path == "/chat/subscribe":
            self.subscription = identifier
            self.reply(ServiceFrame.response(identifier, ApplicationResponse(status=200,
                body=b'{"type":"ack"}\n', end_body=False)))
            return
        if path == "/chat/stream":
            self.uploads.append(bytes(body))
            result = {"result": {"message_id": "voice-note-123"}}
        else:
            result = {"result": {"chat_events": [{"display_text": "你好，蓝牙已连接", "seq": 2}]}}
        self.reply(ServiceFrame.response(identifier,
            ApplicationResponse(status=200, body=json.dumps(result, ensure_ascii=False).encode(), end_body=True)))
        if path == "/chat/stream":
            events = [
                {"type": "event", "event": "message.user", "payload": {"message_id": "voice-note-123", "display_text": "你好"}},
                {"type": "event", "event": "message.assistant", "payload": {"message_id": "assistant-456",
                    "reply_to_message_id": "assistant-456", "display_text": "你好，蓝牙已连接", "display_text_ready": True}}]
            ndjson = b"".join(json.dumps(e, ensure_ascii=False).encode() + b'\n' for e in events)
            self.reply(ServiceFrame.body_chunk(self.subscription, BodyChunk(data=ndjson)))

    def receive(self):
        if self.closed:
            raise ConnectionError("closed")
        try:
            return self.queue.get(timeout=0.1)
        except queue.Empty:
            return None

    def close(self):
        self.closed = True


class Network:
    def __init__(self, expired=False):
        self.channel = Channel()
        self.expired = expired
        self.refreshed = False
        self.closed = False

    def http(self, method, url, headers, body):
        assert json.loads(headers)["X-API-Version"] == "1.0.0"
        if url.endswith("/device_token/refresh"):
            self.refreshed = True
            assert json.loads(headers)["Authorization"] == "Bearer hatch_refresh:refresh-test"
            return json.dumps({"status": 200, "body": json.dumps({"access_token": "new-access", "refresh_token": "new-refresh"})})
        if self.expired and not self.refreshed:
            return json.dumps({"status": 401, "body": "{}"})
        return json.dumps({"status": 200, "body": json.dumps({"vm_list": [{"vm_id": "test-vm", "vm_auth_token": "test-bearer", "default": True}]})})

    def open(self, url, headers):
        assert url == "wss://hatch.metaaivm.com/v1/noise?vm_id=test-vm"
        return self.channel

    def close(self):
        self.channel.close()
        self.closed = True


class Callbacks:
    def __init__(self):
        self.messages = queue.Queue()
        self.status = []
        self.bridge = None

    def setStatus(self, text):
        self.status.append(text)

    def sendMessage(self, kind, identifier, data):
        if kind == TOKENS:
            self.bridge.feed(TOKENS, 0, b'{"ok":true}')
        self.messages.put((kind, identifier, bytes(data)))
        return True

    def wait(self, kind, identifier=0):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=5)
            if message[:2] == (kind, identifier):
                return message[2]
        raise TimeoutError()


class BackendTest(unittest.TestCase):
    def start(self, expired=False):
        callbacks, network = Callbacks(), Network(expired)
        bridge = Bridge(callbacks, network)
        callbacks.bridge = bridge
        bridge.feed(CREDENTIALS, 0, json.dumps({"access_token": "test-access",
            "refresh_token": "hatch_refresh:refresh-test", "device_id": "test-device",
            "node_id": "test-node"}).encode())
        callbacks.wait(READY)
        self.addCleanup(self.stop, bridge)
        return bridge, callbacks, network

    def stop(self, bridge):
        bridge.stop()
        bridge.thread.join(3)
        self.assertFalse(bridge.thread.is_alive())
        self.assertIsNone(bridge.credentials)

    def test_voice_upload_and_unicode_response(self):
        bridge, cb, net = self.start()
        pcm = bytes(range(256)) * 16
        voice = json.dumps({"attachments": [{"content_base64": base64.b64encode(pcm).decode()}]}).encode()
        bridge.feed(OPEN, 2, b'{"verb":"POST","path":"/chat/stream","headers":[["Content-Type","application/json"]],"end":false}')
        bridge.feed(DATA, 2, b'\x00' + voice[:2000])
        bridge.feed(DATA, 2, b'\x01' + voice[2000:])
        response = cb.wait(RESPONSE, 2)
        self.assertEqual(struct.unpack_from('<hB', response), (200, 1))
        self.assertEqual(net.channel.uploads, [voice])
        bridge.feed(OPEN, 3, b'{"verb":"GET","path":"/chat/history?limit=1&after_seq=1","end":true}')
        reply = cb.wait(RESPONSE, 3)
        self.assertIn("你好，蓝牙已连接", reply[3:].decode())
        self.assertFalse(any(p.startswith("/chat/history") for p, _ in net.channel.requests.values()))
        bridge.feed(OPEN, 4, b'{"verb":"GET","path":"/passport/reader?note=voice-note-123&page=-1","end":true}')
        page = cb.wait(RESPONSE, 4)
        self.assertEqual(struct.unpack_from('<hB', page), (200, 1))
        result = json.loads(page[3:])
        self.assertEqual(result['role'], 'assistant')
        self.assertEqual(result['text'], '你好，蓝牙已连接')
        bridge.feed(OPEN, 5, b'{"verb":"GET","path":"/passport/reader?note=voice-note-123&page=0","end":true}')
        result = json.loads(cb.wait(RESPONSE, 5)[3:])
        self.assertEqual(result['role'], 'user')
        self.assertEqual(result['text'], '你好')
        self.assertFalse(any(p.startswith("/passport/") for p, _ in net.channel.requests.values()))

    def test_compressed_audio_becomes_real_wav_through_noise(self):
        bridge, cb, net = self.start()
        bridge.feed(OPEN, 2, b'{"verb":"POST","path":"/chat/stream","audio":"ima-adpcm-16000-v1","end":false}')
        for seq in range(10):
            block=struct.pack('<hBHI',0,0,320,seq)+bytes(160)
            bridge.feed(DATA,2,b'\x00'+block)
        bridge.feed(DATA,2,b'\x01')
        cb.wait(RESPONSE,2)
        body=json.loads(net.channel.uploads[0])
        wav=base64.b64decode(body['items'][0]['data_base64'],validate=True)
        self.assertEqual(wav[:4],b'RIFF')
        self.assertEqual(struct.unpack_from('<I',wav,24)[0],16000)
        self.assertEqual(len(wav),44+3200*2)
        self.assertEqual(wav[44:],bytes(6400))

    def test_expired_token_commit_before_register(self):
        bridge, cb, net = self.start(expired=True)
        self.assertTrue(net.refreshed)
        self.assertEqual(bridge.credentials['refresh_token'], 'new-refresh')

    def test_disallowed_path_fails_closed(self):
        bridge, cb, net = self.start()
        bridge.feed(OPEN, 9, b'{"verb":"GET","path":"/private/unsupported","end":true}')
        self.assertEqual(cb.wait(RESPONSE, 9), struct.pack('<hB', -1, 1))
        self.assertEqual(net.channel.uploads, [])

    def failed_connection(self, network):
        callbacks = Callbacks()
        bridge = Bridge(callbacks, network)
        callbacks.bridge = bridge
        self.addCleanup(self.stop, bridge)
        bridge.feed(CREDENTIALS, 0, b'{"access_token":"test-access","node_id":"test-node"}')
        callbacks.wait(ERROR)
        return callbacks.status[-1]

    def test_api_http_failure_does_not_blame_phone_network(self):
        network = Network()
        network.http = lambda *_: json.dumps({"status": 503, "body": "service unavailable"})
        status = self.failed_connection(network)
        self.assertIn("账号信息获取", status)
        self.assertIn("HTTP 503", status)
        self.assertNotIn("检查手机网络", status)

    def test_empty_vm_list_reports_account_state(self):
        network = Network()
        network.http = lambda *_: json.dumps({"status": 200, "body": '{"vm_list":[]}'})
        status = self.failed_connection(network)
        self.assertIn("账号没有可用的 Muse VM", status)

    def test_websocket_failure_reports_stage_and_sanitized_http_status(self):
        network = Network()
        def fail(*_):
            raise OSError("PASSPORT_WS_HTTP_403 wss://private/?token=secret-bearer")
        network.open = fail
        status = self.failed_connection(network)
        self.assertIn("WebSocket", status)
        self.assertIn("HTTP 403", status)
        self.assertNotIn("secret-bearer", status)

    def test_invalid_api_response_does_not_become_empty_account(self):
        network = Network()
        network.http = lambda *_: json.dumps({"status": 200, "body": "<html>private-token</html>"})
        status = self.failed_connection(network)
        self.assertIn("无效的 JSON", status)
        self.assertNotIn("private-token", status)


class ConnectionFailureTest(unittest.TestCase):
    def test_transport_markers_do_not_expose_raw_java_exception(self):
        status = connection_failure("Muse 账号信息获取",
            OSError("java.io.IOException: PASSPORT_NET_DNS https://private/?token=secret"))
        self.assertIn("域名解析失败", status)
        self.assertIn("VPN 分应用规则", status)
        self.assertNotIn("secret", status)

    def test_unknown_exception_and_timeout_are_safe(self):
        status = connection_failure("Muse 加密握手", ValueError("Bearer private-token"))
        self.assertIn("ValueError", status)
        self.assertNotIn("private-token", status)
        self.assertIn("超时", connection_failure("Muse 加密握手", TimeoutError()))

    def test_locally_generated_account_error_is_preserved(self):
        status = connection_failure("Muse 账号信息获取", MuseConnectionError("账号没有可用的 Muse VM"))
        self.assertIn("账号没有可用的 Muse VM", status)


if __name__ == '__main__':
    unittest.main()

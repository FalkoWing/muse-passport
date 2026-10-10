"""Regenerates the Swift test vectors from the reference implementations.

The Python bridge (and, for BLE framing, the Android Java class) is the
reference; the Swift bridge core must reproduce these vectors exactly.

Run from the repository root, with a JDK 17 `javac` on PATH or in JAVA_HOME:

    PYTHONPATH=linux/src:android/app/src/main/python \\
        python ios/tools/generate_vectors.py

`--check` writes nothing and exits non-zero when a committed vector is stale.
"""
import hashlib
import json
import os
import random
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519

from audio_codec import AudioUpload
from musegadget.noise import (ApplicationRequest, ApplicationResponse, BodyChunk, Header, NoiseFrameDecoder,
                              NoiseTransport, NoiseXXInitiator, NoiseXXResponder, Reset, ResetCode, ServiceFrame,
                              ServiceRequest, ServiceResponse, decode_service_frame, decode_service_request,
                              decode_service_response, encode_noise_frames, encode_service_frame,
                              encode_service_request, encode_service_response, framing, noise_xx, transport)
from musegadget.noise._proto import ProtoError
from reply_cache import ReplyCache, wrap_pages

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "ios/PassportBridge/Tests/PassportBridgeTests/Fixtures"


def frames():
    java = Path(os.environ["JAVA_HOME"]) / "bin" if os.environ.get("JAVA_HOME") else None
    tool = lambda name: str(java / name) if java else name
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([tool("javac"), "-d", tmp,
                        str(ROOT / "android/app/src/main/java/ai/muse/passport/BridgeProtocol.java"),
                        str(ROOT / "ios/tools/FrameVectors.java")], check=True)
        return json.loads(subprocess.run([tool("java"), "-cp", tmp, "FrameVectors"],
                                         check=True, capture_output=True).stdout)


def audio():
    rng = random.Random(7)

    def block(sequence, count=320, pred=None, index=None, payload=None):
        pred = rng.randrange(-32768, 32768) if pred is None else pred
        index = rng.randrange(0, 89) if index is None else index
        payload = bytes(rng.randrange(256) for _ in range(count // 2)) if payload is None else payload
        return struct.pack("<hBHI", pred, index, count, sequence) + payload

    def run(feeds):
        upload, steps = AudioUpload(), []
        for data, end in feeds:
            step = {"data": data.hex(), "end": end}
            try:
                step["out"] = upload.feed(data, end).decode()
            except ValueError:
                step["error"] = True
            steps.append(step)
        return steps

    good = block(0)
    return {
        "batched blocks then end": run([(block(0) + block(1), False), (block(2) + block(3, 2), False),
                                         (block(4, 318) + block(5), True)]),
        "empty end": run([(block(0, 4), False), (b"", True), (b"", True)]),
        "single feed": run([(block(0, 320, -32768, 88) + block(1, 320, 32767, 0), True)]),
        "short header": run([(good[:4], False)]),
        "truncated block": run([(good[:-1], False)]),
        "step index out of range": run([(block(0, index=89), False)]),
        "sequence gap": run([(good, False), (block(2), False)]),
        "odd sample count": run([(block(0, 321, payload=bytes(161)), False)]),
        "empty block": run([(block(0, 0), False)]),
        "oversized block": run([(block(0, 322), False)]),
    }


def event(name, **payload):
    return json.dumps({"type": "event", "event": name, "payload": payload}, ensure_ascii=False).encode() + b"\n"


class Scenario:
    """Records each call and what the reference returned, for Swift to replay."""

    def __init__(self):
        self.cache, self.steps = ReplyCache(), []

    def begin(self):
        self.cache.begin()
        self.steps.append({"op": "begin"})
        return self

    def note(self, identifier, reply=""):
        self.cache.note(identifier, reply)
        self.steps.append({"op": "note", "id": identifier, "reply": reply})
        return self

    def feed(self, data, chunk=None):
        for offset in range(0, len(data), chunk or len(data)):
            part = data[offset:offset + (chunk or len(data))]
            step = {"op": "feed", "hex": part.hex()} if chunk else {"op": "feed", "data": part.decode()}
            try:
                self.cache.feed(part)
            except ValueError:
                step["error"] = True
            self.steps.append(step)
        return self

    def fill(self, byte, count):
        step = {"op": "fill", "byte": byte, "count": count}
        try:
            self.cache.feed(bytes([byte]) * count)
        except ValueError:
            step["error"] = True
        self.steps.append(step)
        return self

    def _ask(self, op, call, path):
        step = {"op": op, "path": path}
        try:
            step["out"] = json.loads(call(path))
        except ValueError:
            step["error"] = True
        self.steps.append(step)
        return self

    def page(self, path):
        return self._ask("page", self.cache.page, path)

    def reader(self, query=""):
        return self._ask("reader", self.cache.reader_page, "/passport/reader" + query)


def turn(note="note", reply=""):
    return Scenario().begin().note(note, reply)


def reply_cache():
    s = {}
    stream = (event("delta.message_start", message_id="reply", reply_to_message_id="note")
              + event("delta.text_append", message_id="reply", text="你好，")
              + event("delta.text_append", message_id="reply", text="Passport")
              + event("delta.message_done", message_id="reply"))
    s["chunked unicode deltas"] = turn().feed(stream, chunk=7).page("/chat/history?after_seq=1")
    s["marker precedes the acknowledgement"] = (
        Scenario().feed(event("message.user", message_id="earlier", display_text="上一轮")).begin().note("note")
        .page("/chat/history?limit=1").page("/chat/history?after_seq=0").page("/chat/history?after_seq=2"))
    s["no marker on the first turn"] = turn().page("/chat/history?limit=1").page("/chat/history?after_seq=0")
    s["another chat's reply stays hidden"] = turn().feed(event(
        "message.assistant", message_id="other", reply_to_message_id="another-note",
        display_text="private other reply")).page("/chat/history?after_seq=1")
    evicted = turn()
    for n in range(40):
        evicted.feed(event("message.assistant", message_id="r%d" % n, reply_to_message_id="note", display_text="回复%d" % n))
    s["oldest rows are evicted beyond 32"] = evicted.page("/chat/history?after_seq=0").reader()
    s["history text is cut at 8000 bytes"] = turn().feed(event(
        "message.assistant", message_id="r", reply_to_message_id="note", display_text="中文😀" * 900)
    ).page("/chat/history?after_seq=1").page("/chat/history?after_seq=1&caption=1").reader("?note=note&page=0")
    s["acknowledged second id and assistant chain"] = (
        turn("uploaded-note", "thread-parent")
        .feed(event("message.assistant", message_id="first", reply_to_message_id="thread-parent", display_text="第一条回复"))
        .feed(event("message.assistant", message_id="second", parent_message_id="first", display_text="继续回复"))
        .page("/chat/history?after_seq=1").page("/chat/history?after_seq=2").reader("?note=uploaded-note"))
    s["completion is not reversed by a pending snapshot"] = (
        turn().feed(event("delta.text_append", message_id="r", text="中文回复", reply_to_message_id="note"))
        .feed(event("delta.message_done", message_id="r"))
        .feed(event("message.assistant", message_id="r", display_text_ready=False))
        .page("/chat/history?after_seq=1"))
    s["self referential assistant ids"] = (
        turn("uploaded-note")
        .feed(event("message.user", message_id="uploaded-note", display_text="你好，请回复一句中文"))
        .feed(event("delta.message_start", message_id="assistant-msg-real", reply_to_message_id="assistant-msg-real"))
        .feed(event("delta.text_append", message_id="assistant-msg-real", text="你好，已经收到你的消息。"))
        .feed(event("delta.message_done", message_id="assistant-msg-real", reply_to_message_id="assistant-msg-real"))
        .page("/chat/history?after_seq=0").page("/chat/history?after_seq=1").reader("?note=uploaded-note"))
    s["self id keeps an explicit parent"] = (
        turn().feed(event("delta.message_start", message_id="r", reply_to_message_id="note"))
        .feed(event("delta.text_append", message_id="r", text="中文回复"))
        .feed(event("delta.message_done", message_id="r", reply_to_message_id="r"))
        .page("/chat/history?after_seq=1"))
    s["self id keeps another turn's parent"] = (
        turn().feed(event("delta.message_start", message_id="other", reply_to_message_id="someone-else"))
        .feed(event("delta.message_done", message_id="other", reply_to_message_id="other", display_text="其他对话"))
        .page("/chat/history?after_seq=1").reader("?note=note"))

    reader = turn().reader("?note=note")
    reader.feed(event("message.user", message_id="note",
                      display_text="第一句话。第二句话。第三句话。" * 12 + "\n[file:audio/wav attachment]"))
    reader.reader("?note=note").reader("?note=note&page=1")
    reader.feed(event("message.assistant", message_id="reply", reply_to_message_id="reply", display_text="回复内容 with words " * 30))
    for page in ("", "&page=0", "&page=3", "&page=4", "&page=999999", "&page=-5", "&page=2&cols=8&lines=3",
                 "&cols=99&lines=0", "&page=x"):
        reader.reader("?note=note" + page)
    s["transcript pages then reply pages"] = reader
    s["streaming reply is not paged until complete"] = (
        turn().feed(event("message.user", message_id="note", display_text="完整的稍后转录"))
        .feed(event("delta.text_append", message_id="r", text="还在生成", reply_to_message_id="note")).reader("?note=note")
        .feed(event("delta.message_done", message_id="r")).reader("?note=note"))
    s["a new turn never leaks the previous one"] = (
        turn().feed(event("message.assistant", message_id="other", reply_to_message_id="someone-else", display_text="另一个对话"))
        .reader("?note=note").feed(event("message.assistant", message_id="r", reply_to_message_id="note", display_text="本轮回复"))
        .reader("?note=note").begin().note("new-note").reader("?note=note").reader("?note=new-note").reader())
    overflow = turn()
    for n in range(3):
        overflow.feed(event("delta.text_append", message_id="r", text="中文" * 4000, reply_to_message_id="note"))
    s["long deltas report truncation"] = (
        overflow.feed(event("delta.message_done", message_id="r")).reader("?note=note")
        .reader("?note=note&page=999999").page("/chat/history?after_seq=1"))
    s["encoded note id and blank values"] = (
        turn("a/b c").feed(event("message.assistant", message_id="r", reply_to_message_id="a/b c", display_text="好的"))
        .reader("?note=a%2Fb+c&page=").reader("?page=0&note=a%2Fb%20c#fragment").reader("?note=a/b"))
    s["malformed input"] = (
        turn().page("/chat/history?after_seq=abc").feed(b"\n  \n" + event("message.user", message_id="note", display_text="好"))
        .feed(b'{"type":"other"}\n{"type":"event","event":"message.user","payload":{}}\n')
        .reader("?note=note").feed(b"not json\n"))
    s["subscription line limit"] = turn().fill(0x78, 1024 * 1024 + 1)

    s["explicit server busy without message id"] = (
        turn().feed(event("agent.status", activity_code="working")).page("/chat/history?after_seq=1")
        .feed(event("task.status", status="completed")).page("/chat/history?after_seq=1")
        .feed(event("agent.status", activity_code="working")).begin().note("new-note").page("/chat/history"))
    s["source following and late transcription"] = (
        turn().feed(event("message.assistant", message_id="r", reply_to_message_id="note", display_text="甲" * 84 + "乙" * 84))
        .reader("?note=note&message=r&offset=84&cols=12&lines=7")
        .feed(event("message.user", message_id="note", display_text="问" * 90))
        .reader("?note=note&message=r&offset=84&cols=12&lines=7")
        .reader("?note=note&message=r&offset=84&cols=12&lines=6")
        .reader("?note=note&message=other&offset=0")
        .reader("?note=note&message=r&offset=-1"))
    s["short replies share a page"] = (
        turn().feed(event("message.assistant", message_id="first", reply_to_message_id="note", display_text="甲"))
        .feed(event("message.assistant", message_id="second", reply_to_message_id="first", display_text="乙"))
        .reader("?note=note&message=second&offset=0&lines=7"))

    wraps = [("", 12, 6), ("ab\n\ncd", 12, 6), ("x" * 72, 12, 6), ("😀" * 150 + "\n\n" + "中文" * 50, 12, 6),
             ("the quick brown fox jumps over the lazy dog", 12, 6), ("a\tb\r\nc  d e", 3, 2),
             (" leading and trailing ", 4, 1), ("\n\n", 12, 6), ("é" * 10, 5, 2)]
    return {"scenarios": {name: scenario.steps for name, scenario in s.items()},
            "wrap": [{"text": text, "cols": cols, "lines": lines, "pages": wrap_pages(text, cols, lines)}
                     for text, cols, lines in wraps]}


def describe(frame):
    """A service frame as plain JSON, the form the Swift tests rebuild it from."""
    value, out = frame.value, {"stream": frame.stream_id, "kind": frame.kind}
    headers = lambda: [[h.key, h.value] for h in value.headers]
    if frame.kind == "request":
        out.update(verb=value.verb, path=value.path, headers=headers(), body=bytes(value.body).hex(), end=value.end_body)
    elif frame.kind == "response":
        out.update(status=value.status, headers=headers(), body=bytes(value.body).hex(), end=value.end_body)
    elif frame.kind == "body_chunk":
        out.update(body=bytes(value.data).hex(), end=value.end_body)
    elif frame.kind == "reset":
        out.update(code=int(value.code), reason=value.reason)
    return out


def pattern(size):
    return bytes((i * 31 + 7) & 0xFF for i in range(size))


def envelope():
    headers = [Header("Content-Type", "application/json"), Header("x-request-id", "abc"), Header("", "v"), Header("k", "")]
    frames = [
        ServiceFrame.request(1, ApplicationRequest("POST", "/chat/stream", headers, b"", False)),
        ServiceFrame.request(0, ApplicationRequest()),
        ServiceFrame.request(2 ** 40, ApplicationRequest("GET", "/x?y=中文", [], b"\x00\xff", True)),
        ServiceFrame.response(3, ApplicationResponse(200, [Header("a", "b")], b"body", True)),
        ServiceFrame.response(-1, ApplicationResponse(-5, [], b"", False)),
        ServiceFrame.response(2 ** 63 - 1, ApplicationResponse(2 ** 31 - 1, [], pattern(300), False)),
        ServiceFrame.body_chunk(4, BodyChunk(b"data", True)),
        ServiceFrame.body_chunk(-(2 ** 63), BodyChunk()),
        ServiceFrame.reset(5, Reset(ResetCode.CANCELLED, "bye")),
        ServiceFrame.reset(5, Reset()),
        ServiceFrame.reset(6, Reset(ResetCode.SERVICE_UNAVAILABLE, "")),
        ServiceFrame(stream_id=7),
        ServiceFrame(),
    ]
    encoded = [{"frame": describe(f), "hex": encode_service_frame(f).hex()} for f in frames]
    for item, frame in zip(encoded, frames):
        assert describe(decode_service_frame(bytes.fromhex(item["hex"]))) == item["frame"]

    # Bytes this client must still read: unknown fields are skipped and the
    # last one-of wins.
    chunk = encode_service_frame(ServiceFrame.body_chunk(4, BodyChunk(b"data", True)))
    reset = encode_service_frame(ServiceFrame.reset(4, Reset(ResetCode.TIMEOUT, "late")))
    lenient = [chunk + b"\x78\x05", b"\x79" + bytes(8) + chunk, chunk + b"\x7d" + bytes(4),
               chunk + b"\x7a\x03abc", chunk + reset, b"\x08\x04\x08\x09" + chunk[2:]]
    bad = [b"\x08\x80", b"\x0a\x00", b"\x00\x00", b"\xc0\xa3\x09\x00", b"\x0b", b"\x12\x05ab", b"\x2a\x02\x08\x07",
           b"\x12\x03\x0a\x01\xff", b"\x1a\x07\x08\x80\x80\x80\x80\x80\x20", b"\x08" + b"\xff" * 10 + b"\x01",
           b"\x08" + b"\xff" * 9 + b"\x02", b"\x11" + bytes(7), b"\x15" + bytes(3), b"\x22\x02\x10"]
    for data in bad:
        try:
            decode_service_frame(data)
        except ProtoError:
            continue
        raise AssertionError("reference accepted %s" % data.hex())
    wrappers = []
    for payload in (b"", b"x", pattern(200)):
        request = encode_service_request(ServiceRequest(payload=payload))
        response = encode_service_response(ServiceResponse(payload=payload))
        assert decode_service_request(request).payload == payload and decode_service_response(response).payload == payload
        wrappers.append({"payload": payload.hex(), "request": request.hex(), "response": response.hex()})
    return {"frames": encoded, "wrappers": wrappers, "bad": [data.hex() for data in bad],
            "lenient": [{"hex": data.hex(), "frame": describe(decode_service_frame(data))} for data in lenient]}


def noise_frames():
    cases = []
    for size, chunk_id in ((0, 0), (0, 9), (1, 1), (65489, -1), (65490, 2 ** 63 - 1), (140000, -(2 ** 63))):
        frames = encode_noise_frames(pattern(size), chunk_id)
        decoder, whole = NoiseFrameDecoder(), None
        for frame in frames:
            whole = decoder.decode(frame)
        assert whole == pattern(size)
        cases.append({"size": size, "chunk_id": chunk_id,
                      "frames": [{"length": len(f), "sha256": hashlib.sha256(f).hexdigest()} for f in frames]})
    return cases


def handshake():
    """One full session with pinned keys and chunk ids, so every byte is reproducible."""
    names = ("initiator_ephemeral", "responder_ephemeral", "responder_static", "initiator_static")
    seeds = {name: bytes(range(1 + 32 * n, 33 + 32 * n)) for n, name in enumerate(names)}
    queue = [seeds[name] for name in names]
    chunk_ids = iter(range(1001, 2000))

    def pinned():
        private = x25519.X25519PrivateKey.from_private_bytes(queue.pop(0))
        public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        return noise_xx._X25519KeyPair(private_key=private, public_key_bytes=public)

    original = noise_xx._generate_x25519_key_pair, framing._random_int64
    noise_xx._generate_x25519_key_pair, framing._random_int64 = pinned, lambda: next(chunk_ids)
    try:
        initiator, responder = NoiseXXInitiator(), NoiseXXResponder(b"hello from the vm")
        initiator.initialize()
        responder.initialize()
        message1 = initiator.write_message1()
        message2 = responder.read_message1_and_write_message2(message1)
        payload = initiator.read_message2(message2)
        message3 = initiator.write_message3()
        responder.read_message3(message3)
        result = {"keys": {name: seed.hex() for name, seed in seeds.items()}, "message1": message1.hex(),
                  "message2": message2.hex(), "message3": message3.hex(), "payload": payload.hex(),
                  "remote_static": initiator.remote_static_public_key().hex(),
                  "handshake_hash": initiator.handshake_hash().hex(),
                  "low_order_points": [point.hex() for point in noise_xx.X25519_LOW_ORDER_POINTS]}
        client = NoiseTransport(*initiator.split())
        server_send, server_receive = responder.split()
        server_decoder, events = NoiseFrameDecoder(), []

        def sent(call, frames):
            for frame in frames:
                whole = server_decoder.decode(server_receive.decrypt_with_ad(b"", frame))
            call["frame"] = describe(transport.decode_request_envelope(whole))
            events.append({"from": "client", **call, "cipher": [frame.hex() for frame in frames]})

        def received(frame, chunk_id):
            cipher = [server_send.encrypt_with_ad(b"", part) for part in
                      encode_noise_frames(transport.encode_response_envelope(frame), chunk_id)]
            decoded = None
            for part in cipher:
                decoded = client.decrypt_frame(part)
            assert (decoded is None) == (frame.kind is None)
            events.append({"from": "vm", "cipher": [part.hex() for part in cipher],
                           "frame": describe(frame) if frame.kind else None})

        subscribe = [Header("Content-Type", "application/json"), Header("Accept", "application/x-ndjson"),
                     Header("x-app-id", "hatch-web")]
        control = client.start_stream_request("POST", "/link-control")
        sent({"call": "start"}, control.frames)
        sent({"call": "chunk"}, client.encrypt_body_chunk(control.stream_id, b"\x02\x00\x00\x00{}"))
        received(ServiceFrame.response(1, ApplicationResponse(200, [], b"", False)), 7)
        request = client.encrypt_http_request("POST", "/chat/subscribe", b"{}", headers=subscribe)
        sent({"call": "request"}, request.frames)
        received(ServiceFrame.body_chunk(1, BodyChunk(b"\x02\x00\x00\x00{}", False)), -3)
        received(ServiceFrame.response(2, ApplicationResponse(200, [Header("content-type", "application/x-ndjson")],
                                                              "回复\n".encode(), False)), 0)
        note = client.start_stream_request("POST", "/chat/stream", headers=[Header("x-request-id", "r1")])
        sent({"call": "start"}, note.frames)
        sent({"call": "chunk"}, client.encrypt_body_chunk(note.stream_id, pattern(1800)))
        sent({"call": "chunk"}, client.encrypt_body_chunk(note.stream_id, b"", end_body=True))
        received(ServiceFrame(stream_id=9), 8)
        received(ServiceFrame.response(3, ApplicationResponse(401, [], b"no", True)), 2 ** 63 - 1)
        sent({"call": "reset"}, client.encrypt_reset(note.stream_id))
        received(ServiceFrame.reset(2, Reset(ResetCode.INTERNAL_ERROR, "boom")), 11)
        result["events"] = events
        return result
    finally:
        noise_xx._generate_x25519_key_pair, framing._random_int64 = original


def noise():
    return {"envelope": envelope(), "noise_frames": noise_frames(), "handshake": handshake()}


VECTORS = {"frames.json": frames, "audio.json": audio, "reply_cache.json": reply_cache, "noise.json": noise}


def main():
    stale = []
    for name, build in VECTORS.items():
        text = json.dumps(build(), ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        path = FIXTURES / name
        if "--check" in sys.argv:
            if not path.exists() or path.read_text() != text:
                stale.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    if stale:
        sys.exit("Stale test vectors: %s. Run ios/tools/generate_vectors.py." % ", ".join(stale))


if __name__ == "__main__":
    main()

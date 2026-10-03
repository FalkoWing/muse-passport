"""Android BLE relay using the unchanged Muse SDK Noise and control protocol.

Credentials live only in memory. Rotated credentials are committed on Passport
before the bridge resumes; neither logs nor APKs contain account credentials.
"""
import asyncio
import json
import struct
import threading
from reply_cache import ReplyCache
from audio_codec import AudioUpload, HEAD
from musegadget.link_client import LinkSession, DeviceDescription, Outcome
from musegadget.noise import Header

HELLO, CREDENTIALS, READY, OPEN, DATA, CANCEL, RESPONSE, ACK, TOKENS, ERROR = range(1, 11)
MAX_RESPONSE = 1024 * 1024


def compact(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


class AndroidSocket:
    def __init__(self, channel):
        self.channel = channel

    async def send(self, data):
        self.channel.send(bytes(data))

    async def recv(self):
        while True:
            value = await asyncio.to_thread(self.channel.receive)
            if value is not None:
                return bytes(value)

    async def close(self):
        self.channel.close()


class PassportDevice(DeviceDescription):
    def register_params(self):
        params = super().register_params()
        params.update(platform="esp32", model_id="esp-link", device_family="link")
        return params


class ForwardResponse:
    def __init__(self, bridge, identifier):
        self.bridge, self.identifier = bridge, identifier
        self.received = 0
        self.ack_body = bytearray()
        self.done = asyncio.get_running_loop().create_future()

    def on_frame(self, frame):
        if self.done.done():
            return
        if frame.kind == "reset":
            status, data, end = -1, b"", True
        elif frame.kind == "response":
            status, data, end = frame.value.status, frame.value.body, frame.value.end_body
        else:
            status, data, end = 0, frame.value.data, frame.value.end_body
        self.received += len(data)
        if self.identifier == getattr(self.bridge.session, "note_request", None) and status >= 0:
            if len(self.ack_body) + len(data) <= 4096:
                self.ack_body.extend(data)
            if end:
                ack = json.loads(self.ack_body)
                result = ack.get("result", ack)
                self.bridge.session.cache.note(result.get("message_id", ""), result.get("reply_to_message_id", ""))
        if self.received > MAX_RESPONSE:
            raise ValueError("Muse response limit")
        for offset in range(0, max(1, len(data)), 1800):
            part = data[offset:offset + 1800]
            last = end and offset + len(part) >= len(data)
            self.bridge.responses.put_nowait((RESPONSE, self.identifier,
                struct.pack("<hB", status if offset == 0 else 0, int(last)) + part))
        if end:
            self.done.set_result(None)


class Subscription:
    def __init__(self, session):
        self.session = session
        self.done = asyncio.get_running_loop().create_future()
        self.ready = False
        self.done.add_done_callback(lambda f: None if f.cancelled() else f.exception())

    def on_frame(self, frame):
        if frame.kind == "reset":
            raise ConnectionError("Muse reply subscription reset")
        if frame.kind == "response":
            if frame.value.status != 200:
                self.session.bridge.status("Muse 拒绝回复订阅 (HTTP %d)" % frame.value.status)
                raise PermissionError("Muse 拒绝回复订阅 (HTTP %d)" % frame.value.status)
            data, end = frame.value.body, frame.value.end_body
            if not self.ready:
                self.ready = True
                self.session.bridge.responses.put_nowait((READY, 0, b""))
                self.session.bridge.status("Muse 已连接，可以按住 Passport 的 OK 键说话")
        else:
            data, end = frame.value.data, frame.value.end_body
        self.session.cache.feed(data)
        if end:
            raise ConnectionError("Muse reply subscription ended")


class PhoneSession(LinkSession):
    def __init__(self, bridge, **kwargs):
        super().__init__(**kwargs)
        self.bridge = bridge
        self.ids = {}
        self.cache = ReplyCache(lambda event, chars, parent_known, aliases:
            print("PassportBridge reply event=%s chars=%d parent_known=%s ack_ids=%d" %
                  (event, chars, parent_known, aliases)))
        self.note_request = None
        self.audio = {}

    def _handle(self, message):
        result = super()._handle(message)
        if message.get("id") == self._register_id and message.get("method") is None:
            if message.get("error"):
                raise ConnectionError("Muse 拒绝设备注册")
            task = asyncio.create_task(self.subscribe())
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        return result

    async def subscribe(self):
        async with self._send_lock:
            frames = self._transport.encrypt_http_request("POST", "/chat/subscribe", b"{}",
                headers=[Header("Content-Type", "application/json"), Header("Accept", "application/x-ndjson"),
                         Header("x-app-id", "hatch-web")])
            self._requests[frames.stream_id] = Subscription(self)
            for packet in frames.frames:
                await self._ws.send(packet)

    async def command(self, kind, identifier, data):
        if self.registered_at is None:
            raise ConnectionError("Muse 尚未连接")
        if kind == OPEN:
            info = json.loads(data)
            if info.get("path", "").split("?")[0] not in ("/chat/history", "/chat/stream", "/passport/reader"):
                raise ValueError("Unsupported request path")
            if info["path"].split("?")[0] in ("/chat/history", "/passport/reader"):
                if info["verb"] != "GET":
                    raise ValueError("Local cache endpoints require GET")
                data = (self.cache.reader_page(info["path"]) if info["path"].split("?")[0] == "/passport/reader"
                        else self.cache.page(info["path"]))
                for offset in range(0, len(data), 1800):
                    part = data[offset:offset + 1800]
                    await self.bridge.responses.put((RESPONSE, identifier,
                        struct.pack("<hB", 200 if offset == 0 else 0, int(offset + len(part) == len(data))) + part))
                return
            self.cache.begin()
            self.note_request = identifier
            if len(self.ids) >= 4 or identifier in self.ids:
                raise ValueError("Request limit")
            encoding = info.get("audio")
            if encoding and encoding != "ima-adpcm-16000-v1":
                raise ValueError("Unsupported audio format; update Passport Bridge")
            if encoding:
                self.audio[identifier] = AudioUpload()
            headers = [Header(str(k), str(v)) for k, v in info.get("headers", [])
                       if k.lower() in ("content-type", "x-request-id", "x-app-id")]
            async with self._send_lock:
                if info["end"]:
                    frames = self._transport.encrypt_http_request(info["verb"], info["path"], headers=headers)
                else:
                    frames = self._transport.start_stream_request(info["verb"], info["path"], headers=headers)
                reply = ForwardResponse(self.bridge, identifier)
                self.ids[identifier] = frames.stream_id
                self._requests[frames.stream_id] = reply
                for packet in frames.frames:
                    await self._ws.send(packet)
            if encoding:
                async with self._send_lock:
                    for packet in self._transport.encrypt_body_chunk(frames.stream_id, HEAD, end_body=False):
                        await self._ws.send(packet)
            def done(future):
                if not future.cancelled():
                    future.exception()
                self.ids.pop(identifier, None)
                self.audio.pop(identifier, None)
                self._requests.pop(frames.stream_id, None)
            reply.done.add_done_callback(done)
        elif kind == DATA:
            stream = self.ids.get(identifier)
            if not stream or not data:
                raise ConnectionError("Request already ended")
            audio = self.audio.get(identifier)
            body = audio.feed(data[1:], bool(data[0])) if audio else data[1:]
            async with self._send_lock:
                for packet in self._transport.encrypt_body_chunk(stream, body, end_body=bool(data[0])):
                    await self._ws.send(packet)
        elif kind == CANCEL:
            stream = self.ids.pop(identifier, None)
            self.audio.pop(identifier, None)
            if stream:
                pending = self._requests.pop(stream, None)
                if pending and not pending.done.done():
                    pending.done.cancel()
                async with self._send_lock:
                    for packet in self._transport.encrypt_reset(stream):
                        await self._ws.send(packet)


class Bridge:
    def __init__(self, callbacks, network):
        self.callbacks, self.network = callbacks, network
        self.loop = asyncio.new_event_loop()
        self.commands = asyncio.Queue(maxsize=32)
        self.responses = asyncio.Queue(maxsize=32)
        self.credentials = None
        self.session = None
        self.connection_task = None
        self.token_committed = None
        self.stopping = False
        self.thread = threading.Thread(target=self._run, daemon=True, name="MuseBridge")
        self.thread.start()

    def status(self, text):
        self.callbacks.setStatus(text)

    def feed(self, kind, identifier, data):
        # Never let Java BLE callbacks block on HTTP, TLS or Noise.
        def enqueue():
            try:
                self.commands.put_nowait((int(kind), int(identifier), bytes(data)))
            except asyncio.QueueFull:
                self.status("蓝牙接收队列已满，请重连")
                self.stop()
        self.loop.call_soon_threadsafe(enqueue)

    def stop(self):
        self.stopping = True
        def cancel():
            for task in asyncio.all_tasks(self.loop):
                task.cancel()
        self.loop.call_soon_threadsafe(cancel)

    async def emit(self, kind, identifier, data):
        if not await asyncio.to_thread(self.callbacks.sendMessage, kind, identifier, bytes(data)):
            raise ConnectionError("Bluetooth disconnected")

    async def _writer(self):
        while True:
            await self.emit(*await self.responses.get())

    async def _http(self, method, path, auth, body=None):
        root = (self.credentials.get("api_url_v2") or "https://api.muse.ai").rstrip("/")
        result = json.loads(await asyncio.to_thread(self.network.http, method, root + path,
            compact({"Authorization": auth, "X-API-Version": "1.0.1", "User-Agent": "MusePassport/1.0.1"}),
            compact(body) if body is not None else ""))
        try:
            payload = json.loads(result["body"])
        except (ValueError, KeyError):
            payload = {}
        return result["status"], payload

    async def _vms(self):
        status, payload = await self._http("GET", "/fetch_vms", "Bearer " + self.credentials["access_token"])
        if status == 401:
            raw = self.credentials.get("refresh_token", "").rsplit(":", 1)[-1]
            if not raw:
                raise PermissionError("设备配对已过期，请在 Muse App 中重新配对")
            body = {"device_id": self.credentials["device_id"]}
            if self.credentials.get("sdk_token"):
                body["sdk_token"] = self.credentials["sdk_token"]
            code, tokens = await self._http("POST", "/device_token/refresh", "Bearer hatch_refresh:" + raw, body)
            if code != 200:
                raise PermissionError("Muse 凭据更新失败 (HTTP %d)，请检查配对" % code)
            tokens = tokens.get("payload", tokens)
            if not tokens.get("access_token") or not tokens.get("refresh_token"):
                raise ValueError("Muse 凭据响应不完整")
            self.token_committed = self.loop.create_future()
            await self.emit(TOKENS, 0, compact({k: tokens[k] for k in ("access_token", "refresh_token")}).encode())
            await asyncio.wait_for(self.token_committed, 15)
            self.credentials.update(tokens)
            status, payload = await self._http("GET", "/fetch_vms", "Bearer " + self.credentials["access_token"])
        if status != 200:
            raise ConnectionError("Muse API HTTP %d" % status)
        candidates = [v for v in payload.get("vm_list", []) if v.get("vm_id") and v.get("vm_auth_token")]
        if not candidates:
            raise ConnectionError("账号没有可用的 Muse VM")
        wanted = self.credentials.get("vm_id", "")
        return next((v for v in candidates if v["vm_id"] == wanted),
                    next((v for v in candidates if v.get("default")), candidates[0]))

    async def _connect(self, url, headers):
        return AndroidSocket(await asyncio.to_thread(self.network.open, url, compact(headers)))

    async def _connections(self):
        delay = 2
        while not self.stopping:
            try:
                self.status("正在通过手机连接 Muse…")
                vm = await self._vms()
                device = PassportDevice(self.credentials["node_id"], "FoloToy AI Passport",
                                        self.credentials.get("version", "0.1"), {})
                self.session = PhoneSession(self, noise_host=self.credentials.get("noise_host") or "hatch.metaaivm.com",
                    vm_id=vm["vm_id"], vm_auth_token=vm["vm_auth_token"], device=device,
                    run_command=lambda *_: {"error": {"code": "unsupported", "message": "Remote commands are not supported"}},
                    connect=self._connect)
                outcome = await self.session.run(asyncio.Event())
                if outcome == Outcome.UNPAIRED:
                    raise PermissionError("Muse 已移除此设备，请重新配对")
                delay = 2
            except asyncio.CancelledError:
                raise
            except PermissionError as error:
                self.status(str(error))
                await self.emit(ERROR, 0, str(error).encode())
                return
            except Exception:
                # Exception text may contain URL query strings or bearer data.
                self.status("Muse 连接失败，正在重试；请检查手机网络")
            finally:
                self.session = None
            await self.emit(ERROR, 0, b"MUSE CONNECTION LOST")
            await asyncio.sleep(delay)
            delay = min(30, delay * 2)

    async def _reader(self):
        while True:
            kind, identifier, data = await self.commands.get()
            if kind == CREDENTIALS:
                if self.credentials is not None:
                    continue
                self.credentials = json.loads(data)
                if not self.credentials.get("access_token"):
                    self.status("Passport 尚未在 Muse App 中配对")
                    continue
                self.connection_task = asyncio.create_task(self._connections())
            elif kind == TOKENS:
                if self.token_committed and not self.token_committed.done():
                    if json.loads(data).get("ok"):
                        self.token_committed.set_result(None)
                    else:
                        self.token_committed.set_exception(ConnectionError("Passport 无法保存更新后的凭据"))
            elif kind in (OPEN, DATA, CANCEL):
                try:
                    if self.session is None:
                        raise ConnectionError("Muse disconnected")
                    await self.session.command(kind, identifier, data)
                except Exception:
                    await self.responses.put((RESPONSE, identifier, struct.pack("<hB", -1, 1)))

    def _run(self):
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_until_complete(asyncio.gather(self._reader(), self._writer()))
        except (asyncio.CancelledError, Exception):
            if not self.stopping:
                self.status("桥接已停止，请重新连接 Passport")
        finally:
            for task in asyncio.all_tasks(self.loop):
                task.cancel()
            self.loop.run_until_complete(asyncio.gather(*asyncio.all_tasks(self.loop), return_exceptions=True))
            self.credentials = None
            self.session = None
            self.network.close()
            self.loop.close()

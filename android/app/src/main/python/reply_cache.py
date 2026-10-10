"""Bounded per-connection reply cache from Muse's public NDJSON subscription."""
import json
from collections import OrderedDict
from urllib.parse import urlsplit, parse_qs


TEXT_LIMIT = 64 * 1024  # full text remains on the phone, not on the ESP32


class ReplyCache:
    def __init__(self, diagnostic=None):
        self.diagnostic = diagnostic
        self.buffer = bytearray()
        self.rows = OrderedDict()
        self.seq = 0
        self.mark = 0
        self.note_id = ""
        self.note_ids = set()
        self.agent_busy = False

    def begin(self):
        self.mark = self.seq
        self.note_id = ""
        self.rows.clear()
        self.note_ids.clear()
        self.agent_busy = False

    def note(self, identifier, reply_identifier=""):
        self.note_id = identifier
        self.note_ids = {value for value in (identifier, reply_identifier) if value}
        if identifier and identifier not in self.rows:
            self._row(identifier, "message.user", "[Voice note]", True, "")

    def _row(self, identifier, event, text, ready, parent):
        # Real Muse delta events may put the assistant's own stream/message
        # ID in reply_to_message_id. This is not a parent link. Treat it like
        # an absent parent and never overwrite a genuine earlier user link.
        if event == "message.assistant" and parent == identifier:
            parent = ""
        if identifier not in self.rows:
            self.seq += 1
            self.rows[identifier] = {"seq": self.seq, "message_id": identifier,
                "event_name": event, "reply_to_message_id": parent,
                "display_text": "", "display_text_ready": ready}
        row = self.rows[identifier]
        raw = text.encode('utf-8')
        truncated = len(raw) > TEXT_LIMIT
        text = raw[:TEXT_LIMIT].decode('utf-8', errors='ignore')
        finished = row.get("finished", False)
        if finished and not ready:
            text = row.get("reader_text", row["display_text"])
        text = text or row.get("reader_text", row.get("display_text", ""))
        row.update(event_name=event, reader_text=text,
                   truncated=bool(truncated or row.get("truncated", False)),
                   display_text=text.encode('utf-8')[:8000].decode('utf-8', errors='ignore'),
                   display_text_ready=bool(ready or finished))
        if ready and event == "message.assistant":
            row["finished"] = True
        if parent:
            row["reply_to_message_id"] = parent
        while len(self.rows) > 32:
            self.rows.popitem(last=False)

    def feed(self, data):
        self.buffer.extend(data)
        if len(self.buffer) > 1024 * 1024:
            raise ValueError("Subscription line limit")
        while b'\n' in self.buffer:
            line, _, rest = self.buffer.partition(b'\n')
            self.buffer = bytearray(rest)
            if not line.strip():
                continue
            item = json.loads(line)
            if item.get("type") != "event":
                continue
            payload = item.get("payload") or {}
            event = item.get("event", "")
            if event in ("agent.status", "task.status"):
                code = payload.get("activity_code")
                status = payload.get("status")
                if isinstance(code, str):
                    self.agent_busy = bool(code and code not in ("online", "idle"))
                elif isinstance(status, str):
                    self.agent_busy = bool(status and status not in ("completed", "failed"))
                continue
            identifier = payload.get("message_id") or item.get("message_id") or payload.get("id")
            if not identifier:
                continue
            parent = payload.get("reply_to_message_id") or payload.get("parent_message_id") or ""
            text = payload.get("display_text") or payload.get("content") or ""
            if event in ("message.user", "message.assistant"):
                self._row(identifier, event, text, payload.get("display_text_ready") is not False, parent)
            elif event == "delta.message_start":
                self._row(identifier, "message.assistant", "", False, parent)
            elif event == "delta.text_append":
                old = self.rows.get(identifier, {})
                self._row(identifier, "message.assistant", old.get("reader_text", old.get("display_text", "")) + payload.get("text", ""), False, parent)
            elif event == "delta.message_done":
                old = self.rows.get(identifier, {})
                self._row(identifier, "message.assistant", text or old.get("reader_text", old.get("display_text", "")), True, parent)
            if self.diagnostic and self.note_id and event in ("message.user", "message.assistant", "delta.message_start", "delta.message_done"):
                row = self.rows.get(identifier, {})
                self.diagnostic(event, len(row.get("display_text", "")), bool(parent in self.note_ids), len(self.note_ids))

    def speech_text(self, note, message):
        if not note or note != self.note_id:
            return None
        related = set(self.note_ids)
        for _ in self.rows:
            for row in self.rows.values():
                if row["event_name"] == "message.assistant" and (
                        not row["reply_to_message_id"] or row["reply_to_message_id"] in related):
                    related.add(row["message_id"])
        row = self.rows.get(message)
        if message not in related or not row or row["event_name"] != "message.assistant" or not row["display_text_ready"]:
            return None
        return row.get("reader_text", row["display_text"])

    def page(self, path):
        query = parse_qs(urlsplit(path).query)
        if "after_seq" not in query:
            # Mark the start of this turn, rather than a user event which can
            # arrive before the upload ACK and the firmware's first poll.
            rows = [{"seq": self.mark, "event_name": "marker"}] if self.mark else []
        else:
            after = int(query["after_seq"][0])
            rows = []
            # Assistant replies can form chains, and ACK may name both the
            # uploaded note and the message it replies to (upstream SDK).
            related = set(self.note_ids)
            for _ in range(len(self.rows)):
                for value in self.rows.values():
                    if value["event_name"] == "message.assistant" and (not value["reply_to_message_id"] or value["reply_to_message_id"] in related):
                        related.add(value["message_id"])
            for row in self.rows.values():
                own_user = row["event_name"] == "message.user" and row["message_id"] in self.note_ids
                parent = row["reply_to_message_id"]
                own_reply = row["event_name"] == "message.assistant" and self.note_id and (
                    parent in self.note_ids or parent in related or not parent)
                if row["seq"] > after and (own_user or own_reply):
                    visible = {k: v for k, v in row.items() if k not in ("finished", "reader_text", "truncated")}
                    if query.get("caption") == ["1"]:
                        visible["display_text"] = visible["display_text"].encode()[:768].decode("utf-8", errors="ignore")
                    if own_reply:
                        visible["reply_to_message_id"] = self.note_id
                    elif own_user:
                        visible["message_id"] = self.note_id
                    rows = [visible]
                    break
        return json.dumps({"ok": True, "result": {"chat_events": rows, "agent_busy": self.agent_busy}},
                          ensure_ascii=False, separators=(",", ":")).encode()

    def reader_page(self, path):
        """Local BLE reader endpoint. Never forwarded to the Muse VM."""
        query = parse_qs(urlsplit(path).query)
        if query.get("note", [""])[0] != self.note_id or not self.note_id:
            return b'{"ok":false}'
        cols = max(1, min(12, int(query.get("cols", [12])[0])))
        lines = max(1, min(7, int(query.get("lines", [6])[0])))
        related = set(self.note_ids)
        for _ in range(len(self.rows)):
            for row in self.rows.values():
                if row["event_name"] == "message.assistant" and (
                    not row["reply_to_message_id"] or row["reply_to_message_id"] in related):
                    related.add(row["message_id"])
        users = []
        replies = []
        reply_starts = {}
        reply_length = 0
        truncated = False
        ready = True
        for identifier, row in self.rows.items():
            text = row.get("reader_text", row["display_text"])
            if row["event_name"] == "message.user" and identifier in self.note_ids:
                text = text.split("\n[file:", 1)[0].strip()
                if text and text != "[Voice note]":
                    users.append(text)
                    truncated |= row.get("truncated", False)
            elif row["event_name"] == "message.assistant" and identifier in related:
                ready &= row["display_text_ready"]
                # Stable completed messages: their page boundaries cannot move
                # under the reader as more streaming tokens arrive.
                if row["display_text_ready"] and text:
                    reply_starts[identifier] = reply_length + (2 if replies else 0)
                    reply_length = reply_starts[identifier] + len(text)
                    replies.append(text)
                    truncated |= row.get("truncated", False)
        user_pages = wrap_pages(users[0] if users else "", cols, lines)
        reply_text = "\n\n".join(replies).encode('utf-8')
        truncated |= len(reply_text) > TEXT_LIMIT
        reply_pages, starts = wrap_page_layout(reply_text[:TEXT_LIMIT].decode('utf-8', errors='ignore'), cols, lines)
        pages = user_pages + reply_pages
        selected = int(query.get("page", [-1])[0])
        if query.get("message") and query.get("offset"):
            message = query["message"][0]
            offset = int(query["offset"][0])
            row = self.rows.get(message)
            if message not in reply_starts or not row or not 0 <= offset < len(row.get("reader_text", "")):
                return b'{"ok":false}'
            source = reply_starts[message] + offset
            selected = len(user_pages) + max((i for i, start in enumerate(starts) if start <= source), default=0)
        elif selected < 0:
            selected = len(user_pages) if reply_pages else 0
        selected = max(0, min(len(pages) - 1, selected))
        is_reply = selected >= len(user_pages)
        offset = len(user_pages) if is_reply else 0
        result = {"ok": True, "page": selected, "pages": len(pages),
                  "role": "assistant" if is_reply else "user",
                  "role_page": selected - offset + 1 if pages else 0,
                  "role_pages": len(reply_pages) if is_reply else len(user_pages),
                  "text": pages[selected] if pages else "",
                  "truncated": truncated, "ready": bool(reply_pages and ready)}
        return json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()


def wrap_pages(text, cols=12, lines=6):
    return wrap_page_layout(text, cols, lines)[0]


def wrap_page_layout(text, cols=12, lines=6):
    """Display pages and their original scalar starts, using the same wrapping.

    CR is omitted and tab becomes a space. Explicit/blank lines count, soft
    wrap spaces are omitted, and source offsets remain in the original text.
    """
    if not text:
        return [], []
    paragraphs = [[]]
    positions = [0]
    for at, cp in enumerate(text):
        if cp == "\r":
            continue
        if cp == "\n":
            paragraphs.append([])
            positions.append(at + 1)
        else:
            paragraphs[-1].append((" " if cp == "\t" else cp, at))
    wrapped, starts = [], []
    for paragraph, position in zip(paragraphs, positions):
        while len(paragraph) > cols:
            end = max((i for i, (cp, _) in enumerate(paragraph[:cols + 1]) if cp == " "), default=0)
            if end <= 0:
                end = cols
            wrapped.append("".join(cp for cp, _ in paragraph[:end]))
            starts.append(paragraph[0][1])
            position = paragraph[end - 1][1] + 1
            paragraph = paragraph[end:]
            if paragraph and paragraph[0][0] == " ":
                paragraph = paragraph[1:]
        wrapped.append("".join(cp for cp, _ in paragraph))
        starts.append(paragraph[0][1] if paragraph else position)
    return (["\n".join(wrapped[i:i + lines]) for i in range(0, len(wrapped), lines)],
            [starts[i] for i in range(0, len(starts), lines)])

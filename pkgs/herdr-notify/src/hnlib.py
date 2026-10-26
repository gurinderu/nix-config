"""Shared rules for herdr-notify: the wire schema, label cleaning and limits.

Imported by the VM side (hook.py, serve.py) and by the Mac agent (agent.py), so
both ends apply the same rules. Stdlib only.

Wire format: one JSON object per line, UTF-8, at most MAX_LINE_BYTES bytes.

  {"v":1,"type":"hello","epoch":"<16 hex>","head":<seq>,"ts":<unix s>}
  {"v":1,"type":"hb","head":<seq>,"ts":<unix s>}
  {"v":1,"type":"event","seq":124,"ts":1793000000,"event":"needs_input",
   "agent":"claude","ws":"w2","tab":"w2:t1","pane":"w2:p1",
   "term":"term_65ead8c4a4dc72","ws_label":"nix-config","tab_label":"",
   "title":"...","focused":false}
  {"v":1,"type":"focus","ok":true,"code":"focused"}
  {"v":1,"type":"error","code":"bad_command"}
"""

import json
import re
import unicodedata

SCHEMA_VERSION = 1
MAX_LINE_BYTES = 1024
LABEL_MAX = 40
# Raw label strings longer than this are rejected before cleaning: no
# legitimate label gets close, and it bounds the cleaning work.
RAW_LABEL_MAX = 256
TTL_SECONDS = 3600
FUTURE_SKEW = 300
MAX_SEQ = 2**53 - 1

EVENTS = ("done", "needs_input")
AGENTS = ("claude", "codex")
# herdr agent_status -> wire event.
STATUS_TO_EVENT = {"done": "done", "blocked": "needs_input"}

ID_RE = re.compile(r"[A-Za-z0-9:_-]{1,32}\Z")
TERM_RE = re.compile(r"term_[0-9a-f]{6,32}\Z")
EPOCH_RE = re.compile(r"[0-9a-f]{16}\Z")
CODE_RE = re.compile(r"[a-z_]{1,32}\Z")

# Dropped outright: controls (incl. ESC, BEL, C1), format chars (bidi
# overrides, zero-width joiners/spaces), private use, surrogates, unassigned.
_DROP = frozenset(("Cc", "Cf", "Co", "Cs", "Cn"))
# Turned into a plain space first, so "a\nb" stays two words.
_SPACE = frozenset("\t\n\r\x0b\x0c\x1c\x1d\x1e\x1f\x85  ")


def clean_label(text, limit=LABEL_MAX):
    """A short, single-line, printable label; "" for anything not a string.

    Letters of every script are kept (pane titles are often Cyrillic)."""
    if not isinstance(text, str):
        return ""
    text = unicodedata.normalize("NFC", text[: RAW_LABEL_MAX * 2])
    out = []
    for ch in text:
        if ch in _SPACE:
            out.append(" ")
            continue
        cat = unicodedata.category(ch)
        if cat in _DROP or cat in ("Zl", "Zp"):
            continue
        out.append(ch)
    text = " ".join("".join(out).split())
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


class Invalid(ValueError):
    """A line that must be dropped; str(exc) is a short reason for the log."""


def _req(cond, reason):
    if not cond:
        raise Invalid(reason)


def _label(obj, key):
    value = obj.get(key, "")
    _req(isinstance(value, str), "%s not a string" % key)
    _req(len(value) <= RAW_LABEL_MAX, "%s too long" % key)
    return clean_label(value)


def parse_line(raw, now):
    """Validate one wire line (bytes, without the newline).

    Returns a new dict holding only known, validated, cleaned fields.
    Raises Invalid for anything else."""
    _req(isinstance(raw, (bytes, bytearray)), "not bytes")
    _req(len(raw) <= MAX_LINE_BYTES, "line too long")
    try:
        obj = json.loads(bytes(raw).decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Invalid("not json")
    _req(isinstance(obj, dict), "not an object")
    _req(obj.get("v") == SCHEMA_VERSION and _is_int(obj.get("v")), "bad version")
    kind = obj.get("type")
    if kind in ("hello", "hb"):
        head = obj.get("head")
        _req(_is_int(head) and 0 <= head <= MAX_SEQ, "bad head")
        out = {"type": kind, "head": head}
        if kind == "hello":
            epoch = obj.get("epoch")
            _req(isinstance(epoch, str) and EPOCH_RE.match(epoch), "bad epoch")
            out["epoch"] = epoch
        return out
    if kind == "focus":
        _req(isinstance(obj.get("ok"), bool), "bad ok")
        code = obj.get("code", "")
        _req(isinstance(code, str) and (code == "" or CODE_RE.match(code)), "bad code")
        return {"type": "focus", "ok": obj["ok"], "code": code}
    if kind == "error":
        code = obj.get("code", "")
        _req(isinstance(code, str) and CODE_RE.match(code), "bad code")
        return {"type": "error", "code": code}
    _req(kind == "event", "unknown type")
    seq, ts = obj.get("seq"), obj.get("ts")
    _req(_is_int(seq) and 1 <= seq <= MAX_SEQ, "bad seq")
    _req(_is_int(ts) and now - TTL_SECONDS <= ts <= now + FUTURE_SKEW, "bad ts")
    _req(obj.get("event") in EVENTS, "bad event")
    _req(obj.get("agent") in AGENTS, "bad agent")
    out = {"type": "event", "seq": seq, "ts": ts,
           "event": obj["event"], "agent": obj["agent"]}
    for key in ("ws", "pane"):
        value = obj.get(key)
        _req(isinstance(value, str) and ID_RE.match(value), "bad " + key)
        out[key] = value
    tab = obj.get("tab", "")
    _req(isinstance(tab, str) and (tab == "" or ID_RE.match(tab)), "bad tab")
    out["tab"] = tab
    term = obj.get("term", "")
    _req(isinstance(term, str) and (term == "" or TERM_RE.match(term)), "bad term")
    out["term"] = term
    for key in ("ws_label", "tab_label", "title"):
        out[key] = _label(obj, key)
    focused = obj.get("focused", False)
    _req(isinstance(focused, bool), "bad focused")
    out["focused"] = focused
    return out


def dumps(obj):
    """Compact one-line JSON, UTF-8 kept as is."""
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"),
                      sort_keys=True)


AGENT_NAMES = {"claude": "Claude", "codex": "Codex"}
TITLES = {"needs_input": "\U0001f514 %s needs you", "done": "✅ %s finished"}


def compose(event):
    """(title, body) for a validated event. The title comes from fixed strings
    only; the body is "workspace > tab > title" with empty and redundant parts
    left out (ProjectAJ14 herdr-warp's rules)."""
    title = TITLES[event["event"]] % AGENT_NAMES[event["agent"]]
    tab = event["tab_label"]
    # herdr names tabs "1", "2", ... until renamed: noise as a destination.
    if tab.isdigit():
        tab = ""
    where = []
    for part in (tab, event["title"]):
        if part and part not in where:
            where.append(part)
    # A tab label that only prefixes the pane title collapses into it.
    if len(where) == 2 and where[1].startswith(where[0]):
        where = [where[1]]
    ws = event["ws_label"]
    if ws and ws not in where:
        where.insert(0, ws)
    return title, " › ".join(where) or "Open herdr to pick it up"

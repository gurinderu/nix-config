"""Forced command for the Mac notifier's ssh key (see ~/.ssh/authorized_keys2).

sshd runs this for every connection with that key and passes what the client
asked for in SSH_ORIGINAL_COMMAND. That string is only ever matched against the
whole-string patterns below; it is never run or interpolated.

  stream <seq> [<epoch>]   hello, spooled events after <seq>, then new ones
                           as they arrive, heartbeats every HB_SECONDS
  focus <pane> <term>      focus that herdr pane in the default session, if
                           it still hosts terminal <term>
"""

import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

import hnlib  # noqa: E402
import hnvm  # noqa: E402

STREAM_RE = re.compile(r"stream (0|[1-9][0-9]{0,15})(?: ([0-9a-f]{16}))?\Z")
FOCUS_RE = re.compile(r"focus ([A-Za-z0-9:_-]{1,32}) (term_[0-9a-f]{6,32})\Z")
POLL_SECONDS = 1.0
HB_SECONDS = 20.0
MAX_STREAM_SECONDS = 12 * 3600
FOCUS_MIN_INTERVAL = 1.0


def out(obj, stream):
    stream.write(hnlib.dumps(dict(obj, v=hnlib.SCHEMA_VERSION)).encode() + b"\n")
    stream.flush()


def run_stream(since, client_epoch, spool, stream, clock=time.time,
               monotonic=time.monotonic, sleep=time.sleep,
               max_seconds=MAX_STREAM_SECONDS):
    epoch, head, entries = spool.snapshot()
    if client_epoch is not None and client_epoch != epoch:
        since = 0
    out({"type": "hello", "epoch": epoch, "head": head, "ts": int(clock())}, stream)
    sent = since
    stamp = None
    start = last_hb = monotonic()
    while True:
        now = clock()
        if stamp is None or spool.stamp() != stamp:
            stamp = spool.stamp()
            new_epoch, head, entries = spool.snapshot()
            if new_epoch != epoch:
                # Spool recreated: start over so the client resets too.
                epoch, sent = new_epoch, 0
                out({"type": "hello", "epoch": epoch, "head": head,
                     "ts": int(now)}, stream)
            for entry in entries:
                if entry["seq"] > sent and entry["ts"] >= now - hnlib.TTL_SECONDS:
                    line = hnlib.dumps(entry).encode()
                    if len(line) <= hnlib.MAX_LINE_BYTES:
                        stream.write(line + b"\n")
                    sent = max(sent, entry["seq"])
            stream.flush()
        if monotonic() - last_hb >= HB_SECONDS:
            out({"type": "hb", "head": head, "ts": int(now)}, stream)
            last_hb = monotonic()
        if monotonic() - start >= max_seconds:
            return 0
        sleep(POLL_SECONDS)


def run_focus(pane, term, spool, stream, call=hnvm.herdr_call, clock=time.time,
              env=None):
    sock = hnvm.default_socket(env)
    with spool.locked():
        last_path = os.path.join(spool.dir, "focus.last")
        try:
            last = os.stat(last_path).st_mtime
        except OSError:
            last = 0.0
        if clock() - last < FOCUS_MIN_INTERVAL:
            out({"type": "focus", "ok": False, "code": "rate_limited"}, stream)
            return 1
        with open(last_path, "w"):
            pass
    reply = call(sock, "pane.get", {"pane_id": pane})
    try:
        found = reply["result"]["pane"]["terminal_id"]
    except (TypeError, KeyError):
        out({"type": "focus", "ok": False, "code": "pane_not_found"}, stream)
        return 1
    if found != term:
        out({"type": "focus", "ok": False, "code": "terminal_changed"}, stream)
        return 1
    reply = call(sock, "pane.focus", {"pane_id": pane})
    ok = isinstance(reply, dict) and "result" in reply
    out({"type": "focus", "ok": ok, "code": "focused" if ok else "focus_failed"}, stream)
    return 0 if ok else 1


def main(env=None, stream=None):
    env = os.environ if env is None else env
    stream = sys.stdout.buffer if stream is None else stream
    cmd = env.get("SSH_ORIGINAL_COMMAND", "")
    spool = hnvm.Spool(hnvm.state_dir(env))
    try:
        m = STREAM_RE.match(cmd)
        if m:
            return run_stream(int(m.group(1)), m.group(2), spool, stream)
        m = FOCUS_RE.match(cmd)
        if m:
            return run_focus(m.group(1), m.group(2), spool, stream, env=env)
        out({"type": "error", "code": "bad_command"}, stream)
        return 2
    except (BrokenPipeError, ConnectionResetError):
        # The client went away. Point stdout at /dev/null so the interpreter's
        # final flush cannot fail too (it would turn exit 0 into 120).
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)

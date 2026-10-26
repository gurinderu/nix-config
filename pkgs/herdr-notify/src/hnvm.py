"""VM-side helpers shared by hook.py and serve.py: the spool and herdr's socket.

Spool layout, under $XDG_STATE_HOME/herdr-notify (0700). Not under /run: the
VM has Linger=no, so /run/user/<uid> disappears without a login session.

  spool.jsonl  one wire event per line (0600), rewritten atomically
  meta.json    {"epoch": "<16 hex>", "next_seq": N}
  lock         flock target; writers exclusive, readers shared
  focus.last   timestamp of the last focus request (rate limit)

Every write drops entries older than TTL_SECONDS, keeps one entry per pane
(the newest), and caps the file at MAX_ENTRIES / MAX_BYTES.
"""

import contextlib
import fcntl
import json
import os
import socket
import time

import hnlib

MAX_ENTRIES = 64
MAX_BYTES = 32 * 1024
SOCKET_TIMEOUT = 2.0
MAX_REPLY_BYTES = 16 * 1024 * 1024


def state_dir(env=None):
    env = os.environ if env is None else env
    base = env.get("XDG_STATE_HOME") or os.path.join(
        env.get("HOME") or os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "herdr-notify")


def default_socket(env=None):
    """The default herdr session's socket. Under ~/.config, not /run, so the
    forced command reaches it without a login session."""
    env = os.environ if env is None else env
    base = env.get("XDG_CONFIG_HOME") or os.path.join(
        env.get("HOME") or os.path.expanduser("~"), ".config")
    return os.path.join(base, "herdr", "herdr.sock")


def herdr_call(path, method, params, timeout=SOCKET_TIMEOUT):
    """One request over herdr's socket API; the decoded reply, or None."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(path)
        req = {"id": "herdr-notify", "method": method, "params": params}
        sock.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while b"\n" not in buf and len(buf) < MAX_REPLY_BYTES:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.split(b"\n", 1)[0]) if buf else None
    except (OSError, ValueError):
        return None
    finally:
        sock.close()


class Spool:
    def __init__(self, directory, clock=time.time):
        self.dir = directory
        self.clock = clock
        self.path = os.path.join(directory, "spool.jsonl")
        self.meta_path = os.path.join(directory, "meta.json")
        self.lock_path = os.path.join(directory, "lock")

    def _ensure_dir(self):
        os.makedirs(self.dir, mode=0o700, exist_ok=True)

    @contextlib.contextmanager
    def locked(self, exclusive=True):
        self._ensure_dir()
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
            yield
        finally:
            os.close(fd)

    def _write_atomic(self, path, data):
        tmp = "%s.tmp.%d" % (path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        os.replace(tmp, path)

    def _read_meta(self):
        try:
            with open(self.meta_path, "rb") as fh:
                meta = json.loads(fh.read(4096))
            if (isinstance(meta, dict)
                    and isinstance(meta.get("epoch"), str)
                    and hnlib.EPOCH_RE.match(meta["epoch"])
                    and isinstance(meta.get("next_seq"), int)
                    and 1 <= meta["next_seq"] <= hnlib.MAX_SEQ):
                return meta
        except (OSError, ValueError):
            pass
        return None

    def _meta(self):
        """Current meta, creating a fresh epoch if missing. Caller holds the
        exclusive lock."""
        meta = self._read_meta()
        if meta is None:
            meta = {"epoch": os.urandom(8).hex(), "next_seq": 1}
            self._write_atomic(self.meta_path, json.dumps(meta).encode())
        return meta

    def _entries(self):
        out = []
        try:
            with open(self.path, "rb") as fh:
                data = fh.read(MAX_BYTES * 4)
        except OSError:
            return out
        for line in data.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if (isinstance(obj, dict) and isinstance(obj.get("seq"), int)
                    and isinstance(obj.get("ts"), int)
                    and isinstance(obj.get("pane"), str)):
                out.append(obj)
        out.sort(key=lambda o: o["seq"])
        return out

    def _store(self, entries):
        now = self.clock()
        entries = [e for e in entries if e["ts"] >= now - hnlib.TTL_SECONDS]
        entries = entries[-MAX_ENTRIES:]
        lines = [hnlib.dumps(e).encode() + b"\n" for e in entries]
        while lines and sum(map(len, lines)) > MAX_BYTES:
            lines.pop(0)
        self._write_atomic(self.path, b"".join(lines))

    def append(self, record):
        """Give `record` the next seq and spool it, replacing the pane's
        previous entry. Returns the seq."""
        with self.locked():
            meta = self._meta()
            seq = meta["next_seq"]
            # Meta first: a crash between the two writes skips a seq rather
            # than reusing one.
            meta["next_seq"] = seq + 1
            self._write_atomic(self.meta_path, json.dumps(meta).encode())
            record = dict(record, seq=seq)
            entries = [e for e in self._entries() if e["pane"] != record["pane"]]
            entries.append(record)
            self._store(entries)
            return seq

    def drop_pane(self, pane):
        """Forget the pane's pending entry (it went back to working/idle)."""
        if not os.path.exists(self.path):
            return False
        with self.locked():
            entries = self._entries()
            kept = [e for e in entries if e["pane"] != pane]
            if len(kept) == len(entries):
                return False
            self._store(kept)
            return True

    def snapshot(self):
        """(epoch, head seq, entries) for a reader; creates the epoch if needed."""
        with self.locked():
            meta = self._meta()
            return meta["epoch"], meta["next_seq"] - 1, self._entries()

    def stamp(self):
        """Cheap change detector for the reader's poll loop."""
        try:
            st = os.stat(self.path)
            mst = os.stat(self.meta_path)
            return (st.st_ino, st.st_mtime_ns, st.st_size, mst.st_ino,
                    mst.st_mtime_ns)
        except OSError:
            return None

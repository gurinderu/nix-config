import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
sys.path.insert(0, SRC)

import hnlib  # noqa: E402
import hnvm  # noqa: E402
import hook  # noqa: E402
import serve  # noqa: E402

NOW = 1_800_000_000

SNAPSHOT = {
    "focused_pane_id": "w1:p1",
    "workspaces": [{"workspace_id": "w2", "label": "nix-config"}],
    "tabs": [{"tab_id": "w2:t1", "label": "1"}],
    "panes": [{"pane_id": "w2:p1", "tab_id": "w2:t1", "workspace_id": "w2",
               "agent": "claude", "agent_status": "blocked",
               "terminal_id": "term_65ead8c4a4dc72",
               "terminal_title_stripped": "Ситуация\x1b с 1400 ‮"}],
    "agents": [],
}


def herdr_event(status="blocked", pane="w2:p1"):
    return json.dumps({"event": "pane_agent_status_changed",
                       "data": {"type": "pane_agent_status_changed", "pane_id": pane,
                                "workspace_id": "w2", "agent_status": status,
                                "agent": "claude"}})


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.env = {"HOME": self.home,
                    "XDG_STATE_HOME": os.path.join(self.home, "state"),
                    "XDG_CONFIG_HOME": os.path.join(self.home, "cfg")}
        os.makedirs(os.path.join(self.home, "cfg", "herdr"))
        self.sock = hnvm.default_socket(self.env)
        self.env["HERDR_SOCKET_PATH"] = self.sock
        self.now = NOW
        self.spool = hnvm.Spool(hnvm.state_dir(self.env), clock=lambda: self.now)

    def tearDown(self):
        self.tmp.cleanup()

    def run_hook(self, event_json, snapshot=SNAPSHOT):
        env = dict(self.env, HERDR_PLUGIN_EVENT_JSON=event_json)
        calls = []

        def call(path, method, params):
            calls.append((path, method, params))
            return {"result": {"snapshot": snapshot}}
        hook.main(env=env, sleep=lambda s: None, clock=lambda: self.now, call=call)
        return calls

    def entries(self):
        return self.spool.snapshot()[2]


class HookTests(Base):
    def test_blocked_is_spooled_clean(self):
        calls = self.run_hook(herdr_event())
        self.assertEqual(calls[0][1], "session.snapshot")
        (e,) = self.entries()
        self.assertEqual(e["event"], "needs_input")
        self.assertEqual(e["title"], "Ситуация с 1400")
        self.assertEqual(e["tab_label"], "")       # numeric tab dropped
        self.assertEqual(e["term"], "term_65ead8c4a4dc72")
        self.assertFalse(e["focused"])
        self.assertEqual(e["seq"], 1)
        hnlib.parse_line(hnlib.dumps(e).encode(), NOW)  # wire-valid

    def test_state_changed_during_debounce(self):
        snap = json.loads(json.dumps(SNAPSHOT))
        snap["panes"][0]["agent_status"] = "working"
        self.run_hook(herdr_event(), snap)
        self.assertEqual(self.entries(), [])

    def test_other_agent_dropped(self):
        snap = json.loads(json.dumps(SNAPSHOT))
        snap["panes"][0]["agent"] = "gemini"
        self.run_hook(herdr_event(), snap)
        self.assertEqual(self.entries(), [])

    def test_named_session_ignored(self):
        env_event = herdr_event()
        self.env["HERDR_SOCKET_PATH"] = os.path.join(self.home, "other.sock")
        self.assertEqual(self.run_hook(env_event), [])

    def test_bad_pane_id_ignored(self):
        self.assertEqual(self.run_hook(herdr_event(pane="w1:p1;id")), [])
        self.assertEqual(self.run_hook("not json"), [])
        self.assertEqual(self.run_hook(""), [])

    def test_coalesce_and_clear(self):
        self.run_hook(herdr_event())
        self.run_hook(herdr_event())
        self.assertEqual([e["seq"] for e in self.entries()], [2])
        self.assertEqual(self.run_hook(herdr_event("working")), [])  # no snapshot call
        self.assertEqual(self.entries(), [])

    def test_ttl_and_caps(self):
        for i in range(100):
            self.spool.append({"ts": self.now, "pane": "w1:p%d" % i, "x": "y" * 300})
        es = self.entries()
        self.assertLessEqual(len(es), hnvm.MAX_ENTRIES)
        self.assertLessEqual(os.path.getsize(self.spool.path), hnvm.MAX_BYTES)
        self.assertEqual(es[-1]["seq"], 100)
        self.now += 3601
        self.spool.append({"ts": self.now, "pane": "w9:p9"})
        self.assertEqual([e["pane"] for e in self.entries()], ["w9:p9"])

    def test_concurrent_writers(self):
        code = ("import sys; sys.path.insert(0, %r); import hnvm, time\n"
                "s = hnvm.Spool(%r)\n"
                "for i in range(25): s.append({'ts': int(time.time()), 'pane': 'w%%s:p%%d' %% (sys.argv[1], i)})\n"
                % (SRC, self.spool.dir))
        procs = [subprocess.Popen([sys.executable, "-I", "-c", code, str(n)]) for n in range(4)]
        for p in procs:
            self.assertEqual(p.wait(), 0)
        spool = hnvm.Spool(self.spool.dir)
        _, head, es = spool.snapshot()
        self.assertEqual(head, 100)
        self.assertEqual(len({e["seq"] for e in es}), len(es))
        self.assertEqual(len(es), 64)

    def test_files_private(self):
        self.run_hook(herdr_event())
        self.assertEqual(os.stat(self.spool.dir).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.spool.path).st_mode & 0o777, 0o600)


class FakeStream(io.BytesIO):
    pass


class ServeTests(Base):
    def lines(self, stream):
        return [json.loads(x) for x in stream.getvalue().splitlines()]

    def test_bad_commands(self):
        for cmd in ["", "id", "stream", "stream x", "stream 01", "stream 1 2",
                    "stream 1; id", "stream 1\nid", "focus w1:p1", "focus w1:p1 term_1",
                    "focus $(id) term_65ead8c4a4dc72", "focus w1:p1 term_65ead8c4a4dc72 x",
                    "stream 99999999999999999"]:
            with self.subTest(cmd=cmd):
                s = FakeStream()
                rc = serve.main(env=dict(self.env, SSH_ORIGINAL_COMMAND=cmd), stream=s)
                self.assertEqual(rc, 2)
                self.assertEqual(self.lines(s), [{"v": 1, "type": "error", "code": "bad_command"}])

    def stream(self, since, epoch=None, **kw):
        s = FakeStream()
        serve.run_stream(since, epoch, self.spool, s, clock=lambda: self.now,
                         sleep=lambda x: None, max_seconds=0, **kw)
        return self.lines(s)

    def test_replay_from_seq(self):
        for i in range(3):
            self.spool.append({"v": 1, "type": "event", "ts": self.now, "pane": "w1:p%d" % i})
        out = self.stream(1)
        self.assertEqual(out[0]["type"], "hello")
        self.assertEqual(out[0]["head"], 3)
        self.assertEqual([o["seq"] for o in out[1:] if o["type"] == "event"], [2, 3])

    def test_epoch_mismatch_replays_all(self):
        self.spool.append({"v": 1, "type": "event", "ts": self.now, "pane": "w1:p1"})
        out = self.stream(5, "0000000000000000")
        self.assertEqual([o["seq"] for o in out if o["type"] == "event"], [1])

    def test_expired_not_sent(self):
        self.spool.append({"v": 1, "type": "event", "ts": self.now, "pane": "w1:p1"})
        self.now += 4000
        out = self.stream(0)
        self.assertEqual([o for o in out if o["type"] == "event"], [])

    def test_live_stream_and_heartbeat(self):
        r, w = os.pipe()
        env = dict(self.env, SSH_ORIGINAL_COMMAND="stream 0")
        old = serve.HB_SECONDS
        serve.HB_SECONDS = 0.5
        script = ("import sys; sys.path.insert(0, %r); import serve; serve.HB_SECONDS = 0.5;"
                  "sys.exit(serve.main())" % SRC)
        proc = subprocess.Popen([sys.executable, "-I", "-c", script], env=env,
                                stdout=w)
        os.close(w)
        serve.HB_SECONDS = old
        try:
            time.sleep(0.5)
            spool = hnvm.Spool(self.spool.dir)
            spool.append({"v": 1, "type": "event", "ts": int(time.time()), "pane": "w1:p1"})
            got, buf, deadline = [], b"", time.time() + 5
            while time.time() < deadline and not ({"event", "hb"} <= {g["type"] for g in got}):
                buf += os.read(r, 4096)
                *done, buf = buf.split(b"\n")
                got += [json.loads(x) for x in done]
            kinds = [g["type"] for g in got]
            self.assertEqual(kinds[0], "hello")
            self.assertIn("event", kinds)
            self.assertIn("hb", kinds)
        finally:
            os.close(r)
            # Reader gone: the next write hits EPIPE and the server exits.
            self.assertEqual(proc.wait(timeout=5), 0)

    def test_focus_checks_terminal(self):
        calls = []

        def call(path, method, params):
            calls.append(method)
            if method == "pane.get":
                return {"result": {"pane": {"terminal_id": "term_aaaaaaaa"}}}
            return {"result": {}}
        s = FakeStream()
        serve.run_focus("w1:p1", "term_bbbbbbbb", self.spool, s, call=call, env=self.env)
        self.assertEqual(self.lines(s)[0]["code"], "terminal_changed")
        self.assertEqual(calls, ["pane.get"])
        os.utime(os.path.join(self.spool.dir, "focus.last"), (0, 0))
        s = FakeStream()
        calls.clear()
        serve.run_focus("w1:p1", "term_aaaaaaaa", self.spool, s, call=call, env=self.env)
        self.assertEqual(self.lines(s)[0], {"v": 1, "type": "focus", "ok": True, "code": "focused"})
        self.assertEqual(calls, ["pane.get", "pane.focus"])
        s = FakeStream()
        serve.run_focus("w1:p1", "term_aaaaaaaa", self.spool, s, call=call, env=self.env)
        self.assertEqual(self.lines(s)[0]["code"], "rate_limited")


class SocketTests(Base):
    def test_herdr_call_roundtrip(self):
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock)
        srv.listen(1)
        seen = {}

        def serve_one():
            conn, _ = srv.accept()
            seen["req"] = json.loads(conn.makefile().readline())
            conn.sendall(b'{"id":"x","result":{"ok":1}}\n')
            conn.close()
        t = threading.Thread(target=serve_one)
        t.start()
        reply = hnvm.herdr_call(self.sock, "pane.focus", {"pane_id": "w1:p1"})
        t.join()
        srv.close()
        self.assertEqual(reply["result"], {"ok": 1})
        self.assertEqual(seen["req"]["method"], "pane.focus")
        self.assertIsNone(hnvm.herdr_call(os.path.join(self.home, "nope"), "x", {}))


if __name__ == "__main__":
    unittest.main()

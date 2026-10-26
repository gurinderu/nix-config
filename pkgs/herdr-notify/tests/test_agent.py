import json
import os
import stat
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import agent  # noqa: E402
import hnlib  # noqa: E402

NOW = 1_800_000_000

PS = """\
    1     0 ??       /sbin/launchd
  500     1 ??       /Applications/Warp.app/Contents/MacOS/stable
  510   500 ttys003  -zsh
  511   510 ttys003  /opt/homebrew/bin/mosh-client
  520   500 ttys004  -zsh
  521   520 ttys004  /nix/store/abc-mosh/bin/mosh-client
  530   500 ttys005  /usr/bin/ssh
  600     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
  610   600 ttys006  /opt/homebrew/bin/mosh-client
  700     1 ??       /Applications/Warp Preview.app/Contents/MacOS/preview
  710   700 ttys007  mosh-client
"""
ARGS = """\
  511 mosh-client -# fluence | 100.72.145.54 60001
  521 mosh-client -# other-host | 10.0.0.5 60002
  530 ssh ubuntu@100.72.145.54
  610 mosh-client -# ubuntu@fluence | 100.72.145.54 60003
  710 mosh-client -# ubuntu@fluence.tail411887.ts.net | 198.18.0.7 60004
"""
VM = {"100.72.145.54", "fluence", "fluence.tail411887.ts.net"}


class Ttys(unittest.TestCase):
    def test_candidates(self):
        procs, args = agent.parse_ps(PS), agent.parse_args(ARGS)
        self.assertEqual(procs[700][2], "/Applications/Warp Preview.app/Contents/MacOS/preview")
        # 521 goes elsewhere, 530 is ssh (zellij, not herdr), 610 is not in Warp.
        self.assertEqual(agent.warp_candidates(procs, args, VM),
                         [(511, "ttys003"), (710, "ttys007")])

    def test_choose_newest_atime_owned_chardev(self):
        def st(atime, uid=1000, mode=stat.S_IFCHR | 0o620):
            return SimpleNamespace(st_atime=atime, st_uid=uid, st_mode=mode)
        table = {"/dev/ttys003": st(10), "/dev/ttys007": st(20),
                 "/dev/ttys008": st(99, uid=0), "/dev/ttys009": st(99, mode=stat.S_IFREG | 0o600)}

        def fake(path):
            if path not in table:
                raise FileNotFoundError(path)
            return table[path]
        cands = [(511, "ttys003"), (710, "ttys007"), (800, "ttys008"), (900, "ttys009"), (1, "ttys010")]
        self.assertEqual(agent.choose_tty(cands, fake, uid=1000), "/dev/ttys007")
        table["/dev/ttys003"] = st(20)
        self.assertEqual(agent.choose_tty(cands, fake, uid=1000), "/dev/ttys003")  # tie -> lowest pid
        self.assertIsNone(agent.choose_tty([], fake, uid=1000))

    def test_osc_cannot_be_broken_out_of(self):
        data = agent.osc777("t;i\x07tle", "b\x1b]0;evil\x07o\x1b\\dy;x\u009c")
        self.assertTrue(data.startswith(b"\x1b]777;notify;"))
        self.assertTrue(data.endswith(b"\x07"))
        inner = data[len(b"\x1b]777;notify;"):-1]
        self.assertNotIn(b"\x1b", inner)
        self.assertNotIn(b"\x07", inner)
        self.assertNotIn("\u009c".encode(), inner)
        self.assertEqual(inner.count(b";"), 1)

    def test_real_pty(self):
        try:
            master, slave = os.openpty()
        except OSError:
            self.skipTest("no pty")
        try:
            path = os.ttyname(slave)
            data = agent.osc777("✅ Claude finished", "nix-config › Ситуация")
            self.assertTrue(agent.write_tty(path, data))
            got = b""
            while len(got) < len(data):
                got += os.read(master, 4096)
            self.assertEqual(got, data)
        finally:
            os.close(master)
            os.close(slave)


def cfg(tmp, **kw):
    base = dict(host="127.0.0.1", port=22, user="ubuntu", key="/nonexistent", known_hosts="/dev/null",
                host_key_alias="fluence", vm_addr=list(VM), state_dir=tmp, ssh="/usr/bin/ssh",
                max_age=900, jump_window=600, warp_bundle_prefix="dev.warp.", focus_on_click=True)
    base.update(kw)
    return SimpleNamespace(**base)


def line(**over):
    base = {"v": 1, "type": "event", "seq": 5, "ts": NOW, "event": "needs_input",
            "agent": "claude", "ws": "w2", "tab": "w2:t1", "pane": "w2:p1",
            "term": "term_65ead8c4a4dc72", "ws_label": "nix-config",
            "tab_label": "", "title": "fix it", "focused": False}
    base.update(over)
    return json.dumps(base).encode()


class AgentLogic(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.a = agent.Agent(cfg(self.tmp.name))
        self.now = NOW
        self.mono = 1000.0
        self.a.clock = lambda: self.now
        self.a.monotonic = lambda: self.mono
        self.a.limiter = agent.RateLimiter(clock=lambda: self.mono)
        self.writes = []
        self.front = "com.apple.Safari"
        self.a.front_bundle = lambda: self.front
        self.a.find_tty = lambda: "/dev/ttys003"
        self.a.write_tty = lambda p, d: self.writes.append((p, d)) or True
        self.focus = []
        self.a.send_focus = lambda p, t: self.focus.append((p, t))

    def tearDown(self):
        self.tmp.cleanup()

    def test_notify_and_dedup(self):
        self.a.handle(b'{"v":1,"type":"hello","epoch":"0123456789abcdef","head":5,"ts":1}')
        self.a.handle(line())
        self.a.handle(line())           # same seq: dropped
        self.a.handle(line(seq=4))      # older: dropped
        self.assertEqual(len(self.writes), 1)
        self.assertIn("Claude needs you".encode(), self.writes[0][1])
        st = json.load(open(os.path.join(self.tmp.name, "state.json")))
        self.assertEqual(st, {"epoch": "0123456789abcdef", "last_seq": 5})

    def test_epoch_change_resets(self):
        self.a.handle(b'{"v":1,"type":"hello","epoch":"0123456789abcdef","head":5}')
        self.a.handle(line(seq=9))
        self.a.handle(b'{"v":1,"type":"hello","epoch":"fedcba9876543210","head":1}')
        self.a.handle(line(seq=1))
        self.assertEqual(len(self.writes), 2)

    def test_stale_not_shown(self):
        self.a.handle(line(ts=NOW - 901))
        self.assertEqual(self.writes, [])
        self.assertEqual(self.a.last_seq, 5)

    def test_invalid_not_shown(self):
        self.a.handle(line(pane="$(id)"))
        self.a.handle(b"garbage")
        self.assertEqual(self.writes, [])

    def test_rate_limit_and_summary(self):
        for seq in range(1, 11):
            self.a.handle(line(seq=seq, pane="w1:p%d" % seq))
        self.assertEqual(len(self.writes), 3)
        self.assertEqual(self.a.suppressed, 7)
        self.mono += 61
        self.a.maybe_summary()
        self.assertIn(b"7 more agent notifications", self.writes[-1][1])

    def test_no_tty_drops(self):
        self.a.find_tty = lambda: None
        self.a.handle(line())
        self.assertIsNone(self.a.jump_target)

    def test_jump_latest_wins(self):
        self.a.handle(line(seq=1, pane="w1:p1"))
        self.a.handle(line(seq=2, pane="w3:p2", term="term_aaaaaaaa"))
        self.assertFalse(self.a.jump_once())    # Safari still in front
        self.front = "dev.warp.Warp-Stable"
        self.assertTrue(self.a.jump_once())
        self.assertEqual(self.focus, [("w3:p2", "term_aaaaaaaa")])
        self.assertFalse(self.a.jump_once())    # fires once
        self.assertEqual(len(self.focus), 1)

    def test_jump_not_armed_when_warp_in_front(self):
        self.front = "dev.warp.Warp-Stable"
        self.a.handle(line())
        self.assertIsNone(self.a.jump_target)

    def test_jump_expires(self):
        self.a.handle(line())
        self.mono += 601
        self.front = "dev.warp.Warp-Stable"
        self.assertFalse(self.a.jump_once())
        self.assertEqual(self.focus, [])

    def test_jump_flag_off(self):
        self.a.cfg.focus_on_click = False
        self.a.handle(line())
        self.assertIsNone(self.a.jump_target)

    def test_no_term_no_jump(self):
        self.a.handle(line(term=""))
        self.assertIsNone(self.a.jump_target)

    def test_ssh_argv_fixed(self):
        argv = self.a.ssh_argv("stream 5 0123456789abcdef")
        self.assertEqual(argv[:3], ["/usr/bin/ssh", "-F", "/dev/null"])
        self.assertEqual(argv[-1], "stream 5 0123456789abcdef")
        self.assertIn("IdentitiesOnly=yes", argv)
        self.assertIn("StrictHostKeyChecking=yes", argv)


if __name__ == "__main__":
    unittest.main()

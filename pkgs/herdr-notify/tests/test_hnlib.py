import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import hnlib  # noqa: E402

NOW = 1_800_000_000


def ev(**over):
    base = {"v": 1, "type": "event", "seq": 5, "ts": NOW, "event": "done",
            "agent": "claude", "ws": "w2", "tab": "w2:t1", "pane": "w2:p1",
            "term": "term_65ead8c4a4dc72", "ws_label": "nix-config",
            "tab_label": "", "title": "fix it", "focused": False}
    base.update(over)
    return json.dumps(base).encode()


class CleanLabel(unittest.TestCase):
    def test_keeps_other_scripts(self):
        self.assertEqual(hnlib.clean_label("Ситуация с 1400"), "Ситуация с 1400")

    def test_strips_controls_bidi_zero_width(self):
        s = "a\x1b]777;x\x07b‮ c​d⁦e\x9b"
        self.assertEqual(hnlib.clean_label(s), "a]777;xb cde")

    def test_newlines_become_spaces(self):
        self.assertEqual(hnlib.clean_label("a\nb\r\n\tc d"), "a b c d")

    def test_truncates(self):
        out = hnlib.clean_label("x" * 100)
        self.assertEqual(len(out), 40)
        self.assertTrue(out.endswith("…"))

    def test_non_string(self):
        for v in (None, 5, ["a"], {"a": 1}):
            self.assertEqual(hnlib.clean_label(v), "")


class ParseLine(unittest.TestCase):
    def test_good_event(self):
        out = hnlib.parse_line(ev(title="t\x1b[31mx"), NOW)
        self.assertEqual(out["pane"], "w2:p1")
        self.assertEqual(out["title"], "t[31mx")

    def test_unknown_keys_dropped(self):
        out = hnlib.parse_line(ev(extra="$(rm -rf /)", url="http://x"), NOW)
        self.assertNotIn("extra", out)
        self.assertNotIn("url", out)

    def test_rejects(self):
        bad = [
            b"not json", b"[1,2]", b'"str"', b"{}",
            ev(v=2), ev(v=True), ev(v=1.0), ev(type="other"),
            ev(seq=0), ev(seq=-1), ev(seq=1.5), ev(seq=True), ev(seq="5"), ev(seq=2**60),
            ev(ts=NOW - 3601), ev(ts=NOW + 301), ev(ts=float(NOW)),
            ev(event="idle"), ev(event="blocked"), ev(agent="gemini"), ev(agent=None),
            ev(pane="w1:p1; id"), ev(pane="w1 p1"), ev(pane="$(id)"), ev(pane="a" * 33),
            ev(pane="w1:p1\n"), ev(pane=""), ev(ws=None), ev(tab="x y"),
            ev(term="term_XYZ"), ev(term="term_12345678 ; ls"),
            ev(title=5), ev(title="x" * 257), ev(focused="yes"),
            b"{" + b" " * 2000 + b"}", b"\xff\xfe",
        ]
        for raw in bad:
            with self.subTest(raw=raw[:60]):
                with self.assertRaises(hnlib.Invalid):
                    hnlib.parse_line(raw, NOW)

    def test_hello_hb_focus_error(self):
        h = hnlib.parse_line(b'{"v":1,"type":"hello","epoch":"0123456789abcdef","head":3,"ts":1}', NOW)
        self.assertEqual(h, {"type": "hello", "head": 3, "epoch": "0123456789abcdef"})
        self.assertEqual(hnlib.parse_line(b'{"v":1,"type":"hb","head":0}', NOW)["type"], "hb")
        with self.assertRaises(hnlib.Invalid):
            hnlib.parse_line(b'{"v":1,"type":"hello","epoch":"zz","head":3}', NOW)
        self.assertTrue(hnlib.parse_line(b'{"v":1,"type":"focus","ok":true,"code":"focused"}', NOW)["ok"])
        with self.assertRaises(hnlib.Invalid):
            hnlib.parse_line(b'{"v":1,"type":"error","code":"Bad Code!"}', NOW)


class Compose(unittest.TestCase):
    def e(self, **kw):
        return hnlib.parse_line(ev(**kw), NOW)

    def test_titles_fixed(self):
        self.assertEqual(hnlib.compose(self.e(event="needs_input"))[0], "\U0001f514 Claude needs you")
        self.assertEqual(hnlib.compose(self.e(agent="codex"))[0], "✅ Codex finished")

    def test_body_rules(self):
        self.assertEqual(hnlib.compose(self.e(tab_label="3"))[1], "nix-config › fix it")
        self.assertEqual(hnlib.compose(self.e(tab_label="fix"))[1], "nix-config › fix it")
        self.assertEqual(hnlib.compose(self.e(tab_label="web", title="task"))[1],
                         "nix-config › web › task")
        self.assertEqual(hnlib.compose(self.e(ws_label="", title=""))[1], "Open herdr to pick it up")


if __name__ == "__main__":
    unittest.main()

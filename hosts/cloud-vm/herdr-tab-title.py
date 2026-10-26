"""herdr hook: name tabs after what their Claude Code / Codex agent is doing.

Runs from the herdr-tab-title plugin (hosts/cloud-vm/herdr-tab-title.nix) on
agent and focus events (one tab: the event's) and on `startup` (every tab). A tab is renamed to its agent pane's terminal title
(spinner already stripped by herdr), trimmed to MAX_LEN, but only while the
tab still carries herdr's default numeric label or the label this hook set
last time; any other label is a manual rename and is left alone for good.
The last labels live in $HERDR_PLUGIN_STATE_DIR/labels.json.

herdr spawns hooks detached with nowhere to print, so every failure exits 0
quietly; `touch <state dir>/debug` turns on a breadcrumb log (debug.log).
"""

import fcntl
import json
import os
import re
import subprocess
import sys
import time

MAX_LEN = 32
TIMEOUT = 5
AGENTS = ("claude", "codex")
# Titles that say nothing beyond "an agent runs here".
GENERIC = {"", "claude", "claude code", "codex", "openai codex", "codex cli"}
SHELLISH = re.compile(r"^\S+@\S+:|^[~/]")  # user@host:path, bare paths
DEFAULT_LABEL = re.compile(r"^\d+$")

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
# herdr's per-plugin state dir; the fallback (same path) serves `--all` by hand.
STATE = os.environ.get("HERDR_PLUGIN_STATE_DIR") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "herdr", "plugins", "herdr-tab-title")


def trace(msg):
    if os.path.exists(os.path.join(STATE, "debug")):
        try:
            with open(os.path.join(STATE, "debug.log"), "a") as fh:
                fh.write("%d %s\n" % (int(time.time()), msg))
        except OSError:
            pass


def herdr(*args):
    out = subprocess.run([HERDR, *args], stdin=subprocess.DEVNULL,
                         capture_output=True, timeout=TIMEOUT, check=True)
    return out.stdout


def label_for(pane):
    """The tab label a pane's title gives, or None when it is not useful."""
    title = " ".join((pane.get("terminal_title_stripped") or "").split())
    if (title.lower() in GENERIC or title.lower() == (pane.get("agent") or "")
            or SHELLISH.search(title) or DEFAULT_LABEL.match(title)):
        return None
    if len(title) > MAX_LEN:
        title = title[:MAX_LEN - 1].rstrip() + "…"
    return title


def event_ids(raw):
    """(tab_id, pane_id) of an event ({"event": ..., "data": {...}} or a bare
    payload, ids at top level or under "pane" / "tab"); either may be None."""
    try:
        ev = json.loads(raw)
    except (TypeError, ValueError):
        return None, None
    objs = [ev, ev.get("data")] if isinstance(ev, dict) else []
    objs += [o.get(k) for o in objs if isinstance(o, dict) for k in ("pane", "tab")]
    ids = {}
    for obj in objs:
        if isinstance(obj, dict):
            for key in ("tab_id", "pane_id"):
                if isinstance(obj.get(key), str):
                    ids.setdefault(key, obj[key])
    return ids.get("tab_id"), ids.get("pane_id")


def plan(snapshot, labels, only_tab=None):
    """[(tab_id, new_label)] to apply; updates `labels` (the state) in place."""
    panes = {}
    for p in snapshot.get("panes", []) + snapshot.get("agents", []):
        if isinstance(p, dict) and p.get("pane_id"):
            panes.setdefault(p["pane_id"], {}).update(p)
    focused = {l.get("tab_id"): l.get("focused_pane_id")
               for l in snapshot.get("layouts", []) if isinstance(l, dict)}
    tabs = {t.get("tab_id"): t for t in snapshot.get("tabs", [])
            if isinstance(t, dict) and t.get("tab_id")}
    for tab_id in list(labels):  # forget closed tabs
        if tab_id not in tabs:
            del labels[tab_id]
    todo = []
    for tab_id, tab in tabs.items():
        if only_tab is not None and tab_id != only_tab:
            continue
        current = tab.get("label") or ""
        if not DEFAULT_LABEL.match(current) and current != labels.get(tab_id):
            labels.pop(tab_id, None)  # manual rename: hands off
            continue
        agents = [p for p in panes.values()
                  if p.get("tab_id") == tab_id and p.get("agent") in AGENTS]
        agents.sort(key=lambda p: p.get("pane_id") != focused.get(tab_id))
        want = next((l for l in map(label_for, agents) if l), None)
        if want is None or want == current:
            continue
        todo.append((tab_id, want))
    return todo


def main():
    event = os.environ.get("HERDR_PLUGIN_EVENT") or "manual"
    everything = event == "startup" or sys.argv[1:] == ["--all"]
    tab_id = pane_id = None
    if not everything:
        tab_id, pane_id = event_ids(os.environ.get("HERDR_PLUGIN_EVENT_JSON"))
        if not (tab_id or pane_id):
            trace("%s: no tab/pane id" % event)
            return
    trace("%s: tab %s pane %s" % (event, tab_id, pane_id))
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        snap = json.loads(herdr("api", "snapshot"))["result"]["snapshot"]
        if not everything and not tab_id:
            tab_id = next((p.get("tab_id") for p in snap.get("panes", [])
                           if p.get("pane_id") == pane_id), None)
            if not tab_id:
                return
        path = os.path.join(STATE, "labels.json")
        try:
            with open(path) as fh:
                labels = json.load(fh)
            if not isinstance(labels, dict):
                labels = {}
        except (OSError, ValueError):
            labels = {}
        before = dict(labels)
        for tid, want in plan(snap, labels, tab_id):
            try:
                herdr("tab", "rename", tid, want)
                labels[tid] = want
                trace("%s: %s -> %r" % (event, tid, want))
            except (OSError, subprocess.SubprocessError) as exc:
                trace("%s: rename %s failed: %s" % (event, tid, exc))
        if labels != before:
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(labels, fh, ensure_ascii=False)
            os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never break herdr
        trace("error: %r" % exc)
    sys.exit(0)

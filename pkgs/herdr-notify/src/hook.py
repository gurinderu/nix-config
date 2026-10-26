"""herdr event hook: spool done/needs-input agent events for the Mac notifier.

Runs from the herdr-notify plugin on `pane.agent_status_changed`, with the
event in HERDR_PLUGIN_EVENT_JSON. herdr spawns hooks detached with nowhere to
print, so every failure exits 0 quietly; `touch <state dir>/debug` turns on a
breadcrumb log (<state dir>/debug.log).

Only the default herdr session is handled (the Mac's mosh login attaches to
it); every workspace in it is covered.
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

import hnlib  # noqa: E402
import hnvm  # noqa: E402

# herdr debounces its own toasts by 1 s; blocked flaps briefly while approval
# UIs redraw. Wait a little longer, then re-check the pane's state.
DEBOUNCE_SECONDS = 1.5


def trace(state, msg):
    if not os.path.exists(os.path.join(state, "debug")):
        return
    try:
        with open(os.path.join(state, "debug.log"), "a") as fh:
            fh.write("%d %s\n" % (int(time.time()), msg))
    except OSError:
        pass


def unwrap(raw):
    """herdr delivers {"event": ..., "data": {...}}; accept a bare payload too."""
    try:
        event = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(event, dict):
        return None
    if "agent_status" not in event and isinstance(event.get("data"), dict):
        event = event["data"]
    return event


def same_socket(a, b):
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except (TypeError, ValueError):
        return False


def locate(snapshot, pane_id):
    """(pane, tab, workspace) dicts from a session snapshot, or Nones."""
    pane = None
    for p in snapshot.get("agents", []) + snapshot.get("panes", []):
        if isinstance(p, dict) and p.get("pane_id") == pane_id:
            pane = p
            break
    if pane is None:
        return None, None, None
    tab = next((t for t in snapshot.get("tabs", [])
                if isinstance(t, dict) and t.get("tab_id") == pane.get("tab_id")), None)
    ws = next((w for w in snapshot.get("workspaces", [])
               if isinstance(w, dict)
               and w.get("workspace_id") == pane.get("workspace_id")), None)
    return pane, tab, ws


def build_record(event, snapshot, now):
    """The wire record (without seq) for a herdr event, or None to skip."""
    pane_id = event.get("pane_id")
    status = event.get("agent_status")
    pane, tab, ws = locate(snapshot, pane_id)
    if pane is None or pane.get("agent_status") != status:
        return None  # gone, or no longer in that state after the debounce
    agent = pane.get("agent") or event.get("agent")
    if agent not in hnlib.AGENTS:
        return None
    ws_id = pane.get("workspace_id") or event.get("workspace_id") or ""
    tab_id = pane.get("tab_id") or ""
    term = pane.get("terminal_id") or ""
    if not (isinstance(ws_id, str) and hnlib.ID_RE.match(ws_id)):
        return None
    if not (isinstance(tab_id, str) and (tab_id == "" or hnlib.ID_RE.match(tab_id))):
        tab_id = ""
    if not (isinstance(term, str) and hnlib.TERM_RE.match(term)):
        term = ""
    tab_label = hnlib.clean_label((tab or {}).get("label"))
    if tab_label.isdigit():
        tab_label = ""
    title = hnlib.clean_label(event.get("title") or pane.get("terminal_title_stripped")
                              or pane.get("label"))
    record = {
        "v": hnlib.SCHEMA_VERSION,
        "type": "event",
        "ts": int(now),
        "event": hnlib.STATUS_TO_EVENT[status],
        "agent": agent,
        "ws": ws_id,
        "tab": tab_id,
        "pane": pane_id,
        "term": term,
        "ws_label": hnlib.clean_label((ws or {}).get("label")),
        "tab_label": tab_label,
        "title": title,
        "focused": snapshot.get("focused_pane_id") == pane_id,
    }
    # Leave room for the seq; 40-char labels keep this far below the cap.
    if len(hnlib.dumps(dict(record, seq=hnlib.MAX_SEQ)).encode()) > hnlib.MAX_LINE_BYTES:
        record["title"] = ""
    return record


def main(env=None, sleep=time.sleep, clock=time.time, call=hnvm.herdr_call):
    env = os.environ if env is None else env
    state = hnvm.state_dir(env)
    event = unwrap(env.get("HERDR_PLUGIN_EVENT_JSON"))
    if event is None:
        return 0
    pane_id = event.get("pane_id")
    status = event.get("agent_status")
    if not (isinstance(pane_id, str) and hnlib.ID_RE.match(pane_id)):
        return 0
    sock = env.get("HERDR_SOCKET_PATH") or ""
    if not same_socket(sock, hnvm.default_socket(env)):
        trace(state, "skip non-default session %s" % sock)
        return 0
    spool = hnvm.Spool(state, clock=clock)
    if status not in hnlib.STATUS_TO_EVENT:
        if spool.drop_pane(pane_id):
            trace(state, "cleared %s (%s)" % (pane_id, status))
        return 0
    sleep(DEBOUNCE_SECONDS)
    reply = call(sock, "session.snapshot", {})
    try:
        snapshot = reply["result"]["snapshot"]
    except (TypeError, KeyError):
        trace(state, "no snapshot")
        return 0
    if not isinstance(snapshot, dict):
        return 0
    record = build_record(event, snapshot, clock())
    if record is None:
        trace(state, "skip %s %s" % (pane_id, status))
        return 0
    seq = spool.append(record)
    trace(state, "spooled seq=%d %s %s" % (seq, record["event"], pane_id))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # a hook has nowhere to report; never bother herdr
        sys.exit(0)

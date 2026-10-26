"""Mac side of herdr-notify: stream agent events from the VM, show them via Warp.

One long-lived ssh session (dedicated key, forced command on the VM) carries
JSON lines. Every line is validated (hnlib.parse_line); events become a Warp
desktop notification by writing Warp's OSC 777 sequence

    ESC ] 777 ; notify ; <title> ; <body> BEL

to the tty of the Warp tab whose mosh-client is connected to the VM. Warp then
applies its own notification settings (sound, only while Warp is not in
front), and clicking the banner brings up that Warp tab.

Warp gives no click callback, so click-to-pane is "latest wins" (as in
ProjectAJ14 herdr-warp): after a notification posted while Warp was in the
background, the next time Warp becomes the frontmost app within the jump
window -- by clicking the banner, or by Cmd-Tab -- the agent asks the VM once
to focus that herdr pane.

Nothing from the VM reaches a shell or selects a program: ssh, ps and lsappinfo
are run from fixed argv lists, VM strings only end up as cleaned notification
text and as the (re-validated) pane/terminal ids in the focus request.
"""

import argparse
import json
import os
import random
import re
import select
import stat
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

import hnlib  # noqa: E402

IDLE_TIMEOUT = 60.0          # 3 missed VM heartbeats
WAKE_JUMP = 30.0             # wall clock ran ahead of monotonic: we slept
SELECT_SECONDS = 5.0
STABLE_SECONDS = 60.0        # a session this old resets the backoff
BACKOFF_MAX = 60.0
FLOOD_BACKOFF = 300.0
FLOOD_LINES = 300            # non-heartbeat lines per minute
FLOOD_BYTES = 64 * 1024      # per minute
RATE_PER_MIN = 6
RATE_BURST = 3
SUMMARY_EVERY = 60.0
JUMP_POLL = 0.3
FOCUS_TIMEOUT = 10.0

TTY_RE = re.compile(r"(ttys[0-9]{1,4}|pts/[0-9]{1,4})\Z")
# /Applications/Warp.app/Contents/MacOS/stable (measured by herdr-warp),
# Warp Preview.app, a copy in ~/Applications, ...
WARP_APP_RE = re.compile(r"/Warp[^/]*\.app/Contents/MacOS/")


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    sys.stderr.flush()


# ---------------------------------------------------------------- ttys / OSC

def parse_ps(text):
    """`ps -axo pid=,ppid=,tty=,comm=` -> {pid: (ppid, tty, comm)}.
    comm is last because it may contain spaces."""
    procs = {}
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) != 4:
            continue
        try:
            procs[int(parts[0])] = (int(parts[1]), parts[2], parts[3].strip())
        except ValueError:
            continue
    return procs


def parse_args(text):
    """`ps -axww -o pid=,args=` -> {pid: [argv tokens]} (split on spaces)."""
    out = {}
    for line in text.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            out[int(parts[0])] = parts[1].split()
        except ValueError:
            continue
    return out


def _targets_vm(tokens, vm_addrs):
    for tok in tokens[1:]:
        host = tok.rsplit("@", 1)[-1]
        if host in vm_addrs:
            return True
    return False


def under_warp(pid, procs, limit=64):
    seen = set()
    for _ in range(limit):
        if pid in seen or pid not in procs:
            return False
        seen.add(pid)
        ppid, _tty, comm = procs[pid]
        if WARP_APP_RE.search(comm):
            return True
        if ppid <= 1:
            return False
        pid = ppid
    return False


def warp_candidates(procs, args, vm_addrs, clients=("mosh-client",)):
    """[(pid, tty)] of VM clients (mosh-client by default: on cloud-vm only
    mosh logins attach to herdr, plain ssh lands in zellij) running in Warp."""
    found = []
    for pid, (_ppid, tty, comm) in sorted(procs.items()):
        if os.path.basename(comm) not in clients or not TTY_RE.match(tty):
            continue
        if not _targets_vm(args.get(pid, []), vm_addrs):
            continue
        if under_warp(pid, procs):
            found.append((pid, tty))
    return found


def choose_tty(candidates, stat_fn=os.stat, uid=None):
    """The candidate tty most recently typed into (newest atime, like `w`'s
    idle time); ties go to the lowest pid. Only character devices we own."""
    uid = os.getuid() if uid is None else uid
    best = None
    for pid, tty in candidates:
        path = "/dev/" + tty
        try:
            st = stat_fn(path)
        except OSError:
            continue
        if not stat.S_ISCHR(st.st_mode) or st.st_uid != uid:
            continue
        key = (-st.st_atime, pid)
        if best is None or key < best[0]:
            best = (key, path)
    return None if best is None else best[1]


def osc_safe(text, limit=200):
    """Warp splits the payload on ';' and ends it at BEL/ST: no controls, no
    semicolons, one line."""
    return hnlib.clean_label(text, limit).replace(";", ",")


def osc777(title, body):
    return ("\x1b]777;notify;%s;%s\x07" % (osc_safe(title), osc_safe(body))).encode("utf-8")


def write_tty(path, data):
    """One write() of the whole sequence, so it lands between mosh-client's
    own frame writes rather than inside one (each is a single write too).
    Returns True when every byte went out."""
    fd = os.open(path, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        return os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def run_text(argv, timeout=3.0):
    try:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def front_bundle():
    """Bundle id of the frontmost app ("" if unknown), None without lsappinfo."""
    asn = run_text(["/usr/bin/lsappinfo", "front"])
    if asn is None:
        return None
    info = run_text(["/usr/bin/lsappinfo", "info", "-only", "bundleid", asn.strip()])
    if not info or "=" not in info:
        return ""
    # "CFBundleIdentifier"="dev.warp.Warp-Stable"
    return info.rsplit("=", 1)[-1].strip().strip('"')


# ---------------------------------------------------------------- agent

class RateLimiter:
    def __init__(self, per_min=RATE_PER_MIN, burst=RATE_BURST, clock=time.monotonic):
        self.rate = per_min / 60.0
        self.burst = float(burst)
        self.tokens = float(burst)
        self.clock = clock
        self.last = clock()

    def allow(self):
        now = self.clock()
        self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True
        return False


class Agent:
    def __init__(self, cfg):
        self.cfg = cfg
        self.state_path = os.path.join(cfg.state_dir, "state.json")
        self.epoch, self.last_seq = None, 0
        self.limiter = RateLimiter()
        self.suppressed = 0
        self.last_summary = 0.0
        # Injection points (tests replace these).
        self.ps_text = lambda: run_text(["/bin/ps", "-axo", "pid=,ppid=,tty=,comm="])
        self.args_text = lambda: run_text(["/bin/ps", "-axww", "-o", "pid=,args="])
        self.front_bundle = front_bundle
        self.write_tty = write_tty
        self.clock = time.time
        self.monotonic = time.monotonic
        self.sleep = time.sleep
        # Latest-wins jump target: (pane, term, deadline) or None.
        self.jump_cv = threading.Condition()
        self.jump_target = None
        self.load_state()

    # -- state
    def load_state(self):
        try:
            with open(self.state_path, "rb") as fh:
                st = json.loads(fh.read(4096))
            if isinstance(st.get("epoch"), str) and hnlib.EPOCH_RE.match(st["epoch"]):
                self.epoch = st["epoch"]
            if isinstance(st.get("last_seq"), int) and 0 <= st["last_seq"] <= hnlib.MAX_SEQ:
                self.last_seq = st["last_seq"]
        except (OSError, ValueError, AttributeError):
            pass

    def save_state(self):
        os.makedirs(self.cfg.state_dir, mode=0o700, exist_ok=True)
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump({"epoch": self.epoch, "last_seq": self.last_seq}, fh)
        os.replace(tmp, self.state_path)

    # -- ssh
    def ssh_argv(self, remote_cmd):
        c = self.cfg
        return [c.ssh, "-F", "/dev/null", "-T", "-n",
                "-i", c.key, "-p", str(c.port),
                "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=" + c.known_hosts,
                "-o", "HostKeyAlias=" + c.host_key_alias,
                "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=10", "-o", "ClearAllForwardings=yes",
                "-o", "ForwardAgent=no", "-o", "PermitLocalCommand=no",
                "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "LogLevel=ERROR",
                "%s@%s" % (c.user, c.host), remote_cmd]

    # -- delivery
    def find_tty(self):
        procs = parse_ps(self.ps_text() or "")
        args = parse_args(self.args_text() or "")
        return choose_tty(warp_candidates(procs, args, set(self.cfg.vm_addr)))

    def deliver(self, title, body):
        path = self.find_tty()
        if path is None:
            # No Warp tab is connected to the VM: there is nowhere a click could
            # land, and we would only be guessing which terminal to use. Drop.
            log("drop: no Warp tab with a mosh-client to the VM")
            return False
        try:
            ok = self.write_tty(path, osc777(title, body))
        except OSError as exc:
            log("drop: write %s failed: %s" % (path, exc))
            return False
        if not ok:
            log("partial write to %s" % path)
        return ok

    def notify(self, ev):
        title, body = hnlib.compose(ev)
        front = self.front_bundle() if self.cfg.focus_on_click else None
        if not self.deliver(title, body):
            return False
        log("notified seq=%d %s %s" % (ev["seq"], ev["event"], ev["pane"]))
        # Warp only shows the banner while it is not in front; nothing to
        # click, nothing to arm otherwise.
        if (self.cfg.focus_on_click and ev["term"] and front is not None
                and not front.startswith(self.cfg.warp_bundle_prefix)):
            self.arm(ev["pane"], ev["term"])
        return True

    def maybe_summary(self):
        if self.suppressed and self.monotonic() - self.last_summary >= SUMMARY_EVERY:
            n, self.suppressed = self.suppressed, 0
            self.last_summary = self.monotonic()
            self.deliver("herdr", "%d more agent notifications held back" % n)

    # -- lines
    def handle(self, raw):
        try:
            msg = hnlib.parse_line(raw, self.clock())
        except hnlib.Invalid as exc:
            log("drop line: %s" % exc)
            return None
        kind = msg["type"]
        if kind == "hello":
            if msg["epoch"] != self.epoch:
                if self.epoch is not None:
                    log("spool epoch changed, resetting seq")
                self.epoch, self.last_seq = msg["epoch"], 0
                self.save_state()
        elif kind == "event":
            if msg["seq"] <= self.last_seq:
                return None
            self.last_seq = msg["seq"]
            self.save_state()
            if self.clock() - msg["ts"] > self.cfg.max_age:
                log("stale seq=%d (%ds old), not shown" % (msg["seq"], self.clock() - msg["ts"]))
                return msg
            if not self.limiter.allow():
                self.suppressed += 1
                return msg
            self.notify(msg)
        elif kind in ("error", "focus"):
            log("vm says: %s" % msg)
        return msg

    # -- latest-wins jump
    def arm(self, pane, term):
        with self.jump_cv:
            self.jump_target = (pane, term, self.monotonic() + self.cfg.jump_window)
            self.jump_cv.notify()

    def jump_once(self):
        """One poll of the armed target; True if a focus request was sent."""
        with self.jump_cv:
            target = self.jump_target
        if target is None:
            return False
        pane, term, deadline = target
        if self.monotonic() > deadline:
            with self.jump_cv:
                if self.jump_target == target:
                    self.jump_target = None
            return False
        front = self.front_bundle()
        if not front or not front.startswith(self.cfg.warp_bundle_prefix):
            return False
        with self.jump_cv:
            if self.jump_target != target:
                return False
            self.jump_target = None
        self.send_focus(pane, term)
        return True

    def jump_loop(self):
        while True:
            with self.jump_cv:
                while self.jump_target is None:
                    self.jump_cv.wait()
            self.jump_once()
            self.sleep(JUMP_POLL)

    def send_focus(self, pane, term):
        # Re-validate: these came off the wire, even if parse_line passed them.
        if not (hnlib.ID_RE.match(pane) and hnlib.TERM_RE.match(term)):
            return
        try:
            res = subprocess.run(self.ssh_argv("focus %s %s" % (pane, term)),
                                 stdin=subprocess.DEVNULL, capture_output=True,
                                 timeout=FOCUS_TIMEOUT)
        except (OSError, subprocess.SubprocessError) as exc:
            log("focus %s: %s" % (pane, exc))
            return
        line = res.stdout.split(b"\n", 1)[0]
        try:
            log("focus %s: %s" % (pane, hnlib.parse_line(line, self.clock())))
        except hnlib.Invalid as exc:
            log("focus %s: exit %d, %s" % (pane, res.returncode, exc))

    # -- session
    def session(self):
        """Run one ssh session to the end. Returns why it ended:
        'eof', 'idle', 'wake' or 'flood'."""
        remote = "stream %d" % self.last_seq
        if self.epoch:
            remote += " " + self.epoch
        proc = subprocess.Popen(self.ssh_argv(remote), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE)
        fd = proc.stdout.fileno()
        buf, skipping = b"", False
        last_data = self.monotonic()
        wall, mono = self.clock(), self.monotonic()
        window_start, lines, nbytes = mono, 0, 0
        reason = "eof"
        try:
            while True:
                ready, _, _ = select.select([fd], [], [], SELECT_SECONDS)
                now_wall, now_mono = self.clock(), self.monotonic()
                if (now_wall - wall) - (now_mono - mono) > WAKE_JUMP:
                    reason = "wake"
                    break
                wall, mono = now_wall, now_mono
                if now_mono - window_start >= 60:
                    window_start, lines, nbytes = now_mono, 0, 0
                self.maybe_summary()
                if not ready:
                    if now_mono - last_data > IDLE_TIMEOUT:
                        reason = "idle"
                        break
                    continue
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                last_data = now_mono
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if skipping:
                        skipping = False
                        continue
                    msg = self.handle(line)
                    if msg is None or msg["type"] != "hb":
                        lines += 1
                        nbytes += len(line)
                if len(buf) > hnlib.MAX_LINE_BYTES:
                    log("drop line: too long")
                    buf, skipping = b"", True
                if lines > FLOOD_LINES or nbytes > FLOOD_BYTES:
                    reason = "flood"
                    break
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        return reason

    def run(self):
        if not os.path.exists(self.cfg.key):
            log("no key at %s; generate it (see README) -- sleeping" % self.cfg.key)
            self.sleep(300)
            return 0
        if self.cfg.focus_on_click:
            threading.Thread(target=self.jump_loop, daemon=True).start()
        backoff = 1.0
        while True:
            started = self.monotonic()
            try:
                reason = self.session()
            except OSError as exc:
                log("ssh failed to start: %s" % exc)
                reason = "eof"
            lived = self.monotonic() - started
            if reason == "flood":
                log("VM sent too much, backing off %ds" % FLOOD_BACKOFF)
                delay = FLOOD_BACKOFF
            elif reason == "wake":
                log("woke from sleep, reconnecting")
                backoff, delay = 1.0, 1.0
            else:
                backoff = 1.0 if lived >= STABLE_SECONDS else min(backoff * 2, BACKOFF_MAX)
                delay = backoff
                log("session ended (%s after %ds), retry in %ds" % (reason, lived, delay))
            self.sleep(delay * random.uniform(0.8, 1.2))


def parse_config(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=22)
    p.add_argument("--user", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--known-hosts", required=True)
    p.add_argument("--host-key-alias", required=True)
    p.add_argument("--vm-addr", action="append", required=True,
                   help="host spelling a mosh-client to the VM may carry (repeatable)")
    p.add_argument("--state-dir", required=True)
    p.add_argument("--ssh", default="/usr/bin/ssh")
    p.add_argument("--max-age", type=int, default=900)
    p.add_argument("--jump-window", type=int, default=600)
    p.add_argument("--warp-bundle-prefix", default="dev.warp.")
    p.add_argument("--no-focus-on-click", dest="focus_on_click", action="store_false")
    return p.parse_args(argv)


def main(argv=None):
    return Agent(parse_config(sys.argv[1:] if argv is None else argv)).run()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)

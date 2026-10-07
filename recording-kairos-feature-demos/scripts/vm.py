"""Tiny QMP driver for scripted demo takes.

    from vm import VM
    v = VM("/tmp/demo-drv.sock")
    v.wait_stable()            # screen stopped changing
    v.type("kairos-agent ...", cps=14)
    v.key("ret")
    v.shot("frame.png")

Use a QMP socket of its own: QEMU serves one client per -qmp socket, and the
recorder holds the other one.
"""
import hashlib, json, os, socket, subprocess, time

CHARMAP = {' ': 'spc', '-': 'minus', '.': 'dot', '/': 'slash', '_': 'shift-minus',
           ':': 'shift-semicolon', '=': 'equal', ',': 'comma', ';': 'semicolon',
           '&': 'shift-7', '%': 'shift-5', '*': 'shift-8', '(': 'shift-9',
           ')': 'shift-0', '!': 'shift-1', '|': 'shift-backslash',
           '>': 'shift-dot', '<': 'shift-comma', "'": 'apostrophe',
           '+': 'shift-equal', '#': 'shift-3', '$': 'shift-4', '"': 'shift-apostrophe',
           '?': 'shift-slash', '@': 'shift-2', '~': 'shift-grave_accent',
           '`': 'grave_accent', '[': 'bracket_left', ']': 'bracket_right',
           '{': 'shift-bracket_left', '}': 'shift-bracket_right', '\\': 'backslash',
           '^': 'shift-6'}


class VM:
    def __init__(self, sock):
        self.sock = sock
        self.tmp = "/dev/shm/vmdrv-%d.ppm" % os.getpid()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(300):
            try:
                s.connect(sock)
                break
            except OSError:
                time.sleep(0.1)
        self.f = s.makefile("rw")
        self.f.readline()
        self._cmd("qmp_capabilities")

    def _cmd(self, execute, **args):
        msg = {"execute": execute}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                return r

    def hmp(self, line):
        return self._cmd("human-monitor-command", **{"command-line": line})

    def sendkey(self, k):
        self.hmp("sendkey " + k)

    def key(self, keys, gap=0.35):
        """Space-separated QEMU key names, e.g. 'down down ret' or 'ctrl-t'."""
        for k in keys.split():
            self.sendkey(k)
            time.sleep(gap)

    def type(self, text, cps=14):
        for ch in text:
            if ch.isalpha():
                k = ch if ch.islower() else "shift-" + ch.lower()
            elif ch.isdigit():
                k = ch
            else:
                k = CHARMAP[ch]
            self.sendkey(k)
            time.sleep(1.0 / cps)

    def line(self, text, cps=14, pause=0.4):
        self.type(text, cps)
        time.sleep(pause)
        self.sendkey("ret")

    def frame(self):
        self._cmd("screendump", filename=self.tmp)
        with open(self.tmp, "rb") as fh:
            return fh.read()

    def digest(self):
        return hashlib.sha1(self.frame()).hexdigest()

    def shot(self, png):
        self._cmd("screendump", filename=self.tmp)
        subprocess.run(["convert", self.tmp, png], check=True)

    def size(self):
        # PPM header: "P6\n<w> <h>\n255\n"
        head = self.frame()[:32].split()
        return int(head[1]), int(head[2])

    def wait_size(self, w, h, timeout=300, poll=0.5):
        """Wait for the guest to switch to a given video mode, e.g. the
        installer's 1280x1024 console after GRUB's text mode."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                if self.size() == (w, h):
                    return
            except (IndexError, ValueError):
                pass
            time.sleep(poll)
        raise TimeoutError("guest never switched to %dx%d" % (w, h))

    @staticmethod
    def wait_http(url=None, timeout=300, poll=1.0):
        """The installer serves the web UI from the TUI's own process, so its
        answering is the signal that the installer is on tty1."""
        import urllib.request
        url = url or "http://127.0.0.1:%s/" % os.environ.get("DEMO_WEB_PORT", "18080")
        end = time.time() + timeout
        while time.time() < end:
            try:
                with urllib.request.urlopen(url, timeout=2) as r:
                    if r.status == 200:
                        return
            except Exception:
                pass
            time.sleep(poll)
        raise TimeoutError("%s never answered" % url)

    def sample(self):
        # Every 61st byte of the frame: a blinking cursor touches a handful of
        # these at most, a page change touches hundreds.
        return self.frame()[::61]

    @staticmethod
    def differs(a, b, tolerance=40):
        if a is None or b is None or len(a) != len(b):
            return True
        return sum(x != y for x, y in zip(a, b)) > tolerance

    def wait_change(self, timeout=600, poll=0.5):
        first = self.sample()
        end = time.time() + timeout
        while time.time() < end:
            time.sleep(poll)
            if self.differs(first, self.sample()):
                return True
        raise TimeoutError("screen did not change in %ss" % timeout)

    def wait_stable(self, quiet=3.0, timeout=900, poll=0.5):
        """Return once the screen has not changed for `quiet` seconds,
        ignoring changes as small as a blinking cursor."""
        end = time.time() + timeout
        last_change, prev = time.time(), None
        while time.time() < end:
            s = self.sample()
            if self.differs(prev, s):
                last_change = time.time()
            prev = s
            if time.time() - last_change >= quiet:
                return
            time.sleep(poll)
        raise TimeoutError("screen never settled in %ss" % timeout)

    def wait_serial(self, logfile, *needles, timeout=900, poll=1.0):
        """Wait for each needle to appear in the serial log, in order: the
        second is only looked for after the first one's position."""
        end = time.time() + timeout
        pos, pending = 0, list(needles)
        while time.time() < end:
            try:
                with open(logfile, "rb") as fh:
                    data = fh.read()
            except FileNotFoundError:
                data = b""
            while pending:
                i = data.find(pending[0].encode(), pos)
                if i < 0:
                    break
                pos = i + len(pending[0])
                pending.pop(0)
            if not pending:
                return
            time.sleep(poll)
        raise TimeoutError("%r never appeared in %s" % (pending[0], logfile))

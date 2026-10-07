"""Shared harness for a recorded VM take: QEMU + recorder + a beat log.

    with Take("clip1", disk, iso=iso, out="clip1b.mp4") as t:
        t.beat("welcome screen")
        t.vm.key("ret")
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(__file__))
from vm import VM  # noqa: E402

TOOLS = os.path.dirname(os.path.abspath(__file__))


class Take:
    def __init__(self, name, disk, iso=None, out=None, fps=15):
        self.name, self.disk, self.iso, self.out, self.fps = name, disk, iso, out, fps
        self.beats = []

    def __enter__(self):
        args = [os.path.join(TOOLS, "vm-up.sh"), self.name, self.disk]
        if self.iso:
            args.append(self.iso)
        self.qemu = subprocess.Popen(args)
        self.rec = subprocess.Popen(
            ["python3", os.path.join(TOOLS, "qmprec.py"),
             "/tmp/demo-%s-rec.sock" % self.name, self.out, str(self.fps)])
        self.vm = VM("/tmp/demo-%s-drv.sock" % self.name)
        self.t0 = time.time()
        return self

    def beat(self, what):
        t = time.time() - self.t0
        self.beats.append((t, what))
        print("[%6.1fs] %s" % (t, what), flush=True)

    def hold(self, seconds):
        time.sleep(seconds)

    def __exit__(self, *exc):
        self.beat("end of take")
        time.sleep(2)
        open(self.out + ".stop", "w").close()
        self.rec.wait(timeout=60)
        # ACPI power button first so the installed disk shuts down clean
        # (later clips boot it again); hard quit only if that stalls.
        try:
            self.vm.hmp("system_powerdown")
            self.qemu.wait(timeout=60)
        except Exception:
            try:
                self.vm.hmp("quit")
            except Exception:
                pass
            self.qemu.wait(timeout=30)
        with open(self.out + ".beats.txt", "w") as fh:
            for t, what in self.beats:
                fh.write("%02d:%04.1f  %s\n" % (t // 60, t % 60, what))
        return False

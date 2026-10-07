#!/usr/bin/env python3
"""Real-time screen recorder for a QEMU guest.

Keeps one QMP connection open, screendumps into /dev/shm at a fixed rate and
pipes every frame straight into ffmpeg, so nothing big lands on disk. When a
screendump is slower than the frame interval the previous frame is repeated,
which keeps the video's timeline equal to wall-clock time (the splash clip
depends on that). Every frame is scaled and padded onto one canvas because the
guest switches modes (GRUB 640x480, console 1280x1024).

Usage: qmprec.py QMP_SOCK OUT.mp4 [FPS] [WxH]
Stop:  touch OUT.mp4.stop  (or SIGINT)
"""
import json, os, signal, socket, subprocess, sys, time

sock, out = sys.argv[1], sys.argv[2]
fps = float(sys.argv[3]) if len(sys.argv) > 3 else 15
w, h = (sys.argv[4] if len(sys.argv) > 4 else "1280x1024").split("x")
stop = out + ".stop"
tmp = "/dev/shm/qmprec-%d.ppm" % os.getpid()


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(300):
        try:
            s.connect(sock)
            break
        except OSError:
            time.sleep(0.1)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    f.readline()
    return f


def dump(f):
    f.write(json.dumps({"execute": "screendump", "arguments": {"filename": tmp}}) + "\n")
    f.flush()
    while True:  # skip async events until the command's reply
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            break
    with open(tmp, "rb") as fh:
        return fh.read()


vf = ("scale=w=%s:h=%s:force_original_aspect_ratio=decrease:flags=neighbor,"
      "pad=%s:%s:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p" % (w, h, w, h))
ff = subprocess.Popen(
    ["ffmpeg", "-loglevel", "error", "-y", "-f", "image2pipe", "-c:v", "ppm",
     "-framerate", str(fps), "-i", "-", "-vf", vf, "-c:v", "libx264",
     "-preset", "veryfast", "-crf", "18", "-movflags", "+faststart", out],
    stdin=subprocess.PIPE)
running = True
signal.signal(signal.SIGINT, lambda *_: globals().__setitem__("running", False))
signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("running", False))

f = connect()
step = 1.0 / fps
start = time.monotonic()
n, last = 0, None
try:
    while running and not os.path.exists(stop):
        try:
            frame = dump(f)
        except (OSError, ValueError):
            break  # VM went away
        if frame:
            last = frame
        if last is None:
            continue
        # emit as many frames as wall-clock time says we owe
        due = int((time.monotonic() - start) / step) + 1
        while n < due:
            ff.stdin.write(last)
            n += 1
        sleep = start + n * step - time.monotonic()
        if sleep > 0:
            time.sleep(sleep)
finally:
    ff.stdin.close()
    ff.wait()
    for p in (tmp, stop):
        if os.path.exists(p):
            os.remove(p)
    print("recorded %d frames (%.1fs) to %s" % (n, n / fps, out))

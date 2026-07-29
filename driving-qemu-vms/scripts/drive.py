#!/usr/bin/env python3
# Drive a QEMU guest via QMP: type text, send special keys, screendump.
# Usage:
#   drive.py SOCK type "some text"
#   drive.py SOCK key ret|ctrl-d|down|up|spc|...
#   drive.py SOCK shot /path/frame.ppm
import json, socket, sys, time

SOCK = sys.argv[1]
ACTION = sys.argv[2]
ARG = sys.argv[3] if len(sys.argv) > 3 else ""

CHARMAP = {' ': 'spc', '-': 'minus', '.': 'dot', '/': 'slash', '_': 'shift-minus',
           ':': 'shift-semicolon', '=': 'equal', ',': 'comma', ';': 'semicolon',
           '&': 'shift-7', '%': 'shift-5', '*': 'shift-8', '(': 'shift-9',
           ')': 'shift-0', '!': 'shift-1', '|': 'shift-backslash',
           '>': 'shift-dot', '<': 'shift-comma', "'": 'apostrophe',
           '+': 'shift-equal', '#': 'shift-3', '$': 'shift-4', '"': 'shift-apostrophe',
           '?': 'shift-slash', '@': 'shift-2'}


def hmp(f, cmd):
    f.write(json.dumps({"execute": "human-monitor-command",
                        "arguments": {"command-line": cmd}}) + "\n")
    f.flush()
    return f.readline()


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(50):
        try:
            s.connect(SOCK); break
        except OSError:
            time.sleep(0.2)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
    f.readline()
    return f


def keys_for(ch):
    if ch.isalpha() and ch.islower():
        return [ch]
    if ch.isalpha() and ch.isupper():
        return ["shift-" + ch.lower()]
    if ch.isdigit():
        return [ch]
    if ch in CHARMAP:
        return [CHARMAP[ch]]
    raise ValueError("unmapped char %r" % ch)


f = connect()
if ACTION == "type":
    for ch in ARG:
        for qc in keys_for(ch):
            hmp(f, "sendkey " + qc)
            time.sleep(0.02)
elif ACTION == "key":
    # allow multiple space-separated keys: "down down ret"
    for k in ARG.split():
        hmp(f, "sendkey " + k)
        time.sleep(0.05)
elif ACTION == "shot":
    print(hmp(f, "screendump " + ARG).strip())
else:
    sys.exit("unknown action " + ACTION)

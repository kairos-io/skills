#!/usr/bin/env python3
# Minimal QMP client: run one HMP command (e.g. screendump / sendkey) on a
# QEMU started with -qmp unix:SOCK,server,nowait.
# Usage: qmp.py SOCK "screendump /path/frame.ppm"
#        qmp.py SOCK "sendkey ctrl-d"
import json, socket, sys, time

sock_path, hmp = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(50):
    try:
        s.connect(sock_path); break
    except OSError:
        time.sleep(0.2)
else:
    print("could not connect", file=sys.stderr); sys.exit(1)

f = s.makefile("rw")
f.readline()                                   # greeting
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
f.readline()                                   # capabilities ack
f.write(json.dumps({"execute": "human-monitor-command",
                    "arguments": {"command-line": hmp}}) + "\n")
f.flush()
print(f.readline().strip())

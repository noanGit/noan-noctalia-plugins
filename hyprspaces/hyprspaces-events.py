#!/usr/bin/env python3
"""hyprspaces event helper: watch Hyprland's IPC event socket and touch a stamp
file on any event, so the widget can react to changes instantly instead of
polling `hyprctl` at high frequency."""
import os
import socket
import sys
import time

STAMP = "/tmp/noctalia-hyprspaces-events.stamp"

def main():
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not sig:
        # fall back: newest instance dir
        base = os.path.join(runtime, "hypr")
        candidates = [os.path.join(base, d) for d in os.listdir(base)]
        candidates = [c for c in candidates if os.path.exists(os.path.join(c, ".socket2.sock"))]
        if not candidates:
            sys.exit(1)
        sig_dir = max(candidates, key=os.path.getmtime)
    else:
        sig_dir = os.path.join(runtime, "hypr", sig)
    sock_path = os.path.join(sig_dir, ".socket2.sock")

    while True:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(sock_path)
            buf = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
                # only structural events matter for the widget
                if b"workspace" in buf or b"openwindow" in buf or b"closewindow" in buf \
                   or b"movewindow" in buf or b"activewindow" in buf or b"urgent" in buf \
                   or b"monitoradded" in buf or b"monitorremoved" in buf:
                    try:
                        with open(STAMP, "w") as f:
                            f.write(str(time.time()))
                    except OSError:
                        pass
                    buf = b""
                elif len(buf) > 65536:
                    buf = b""
        except OSError:
            pass
        try:
            sock.close()
        except Exception:
            pass
        time.sleep(1.0)  # reconnect after a compositor restart


if __name__ == "__main__":
    main()

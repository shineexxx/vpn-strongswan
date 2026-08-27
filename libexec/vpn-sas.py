#!/usr/bin/env python3
"""Parse `swanctl --list-sas` into something per-user.

  --who         table of who is connected
  --ids NAME    unique IKE_SA ids belonging to NAME, one per line
  --idle SECS   ids of SAs whose tunnel has carried nothing for SECS
"""
import re
import sys

SA_RE = re.compile(r"^\S+: #(\d+), (\w+)")
PEER_RE = re.compile(r"@ (\S+?)\[\d+\] EAP: '([^']*)'(?: \[([^\]]*)\])?")
EST_RE = re.compile(r"established (\d+)([smhd]) ago")
# "in  c6bec1f1, 2345277 bytes, 17407 packets,     1s ago" -- the trailing
# "ago" is absent when the SA has never carried a packet.
USE_RE = re.compile(r"^\s+(?:in|out)\s+\w+,\s+\d+ bytes,\s+\d+ packets(?:,\s+(\d+)([smhd]) ago)?")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}

sessions, cur = [], None
for line in sys.stdin:
    m = SA_RE.match(line)
    if m:
        cur = {"id": m.group(1), "state": m.group(2), "user": "?",
               "peer": "?", "vips": "", "age": "?",
               "age_s": None, "last_use": None}
        sessions.append(cur)
        continue
    if cur is None:
        continue
    m = PEER_RE.search(line)
    if m:
        cur["peer"], cur["user"] = m.group(1), m.group(2)
        cur["vips"] = m.group(3) or ""
        continue
    m = EST_RE.search(line)
    if m:
        n, unit = int(m.group(1)), m.group(2)
        secs = n * UNITS[unit]
        cur["age_s"] = secs
        cur["age"] = (f"{secs//3600}h{secs%3600//60:02d}m" if secs >= 3600
                      else f"{secs//60}m" if secs >= 60 else f"{secs}s")
        continue
    m = USE_RE.match(line)
    if m:
        if m.group(1) is None:
            continue                      # never used -- leave last_use unset
        used = int(m.group(1)) * UNITS[m.group(2)]
        if cur["last_use"] is None or used < cur["last_use"]:
            cur["last_use"] = used

mode = sys.argv[1] if len(sys.argv) > 1 else "--who"

if mode == "--idle":
    limit = int(sys.argv[2])
    for s_ in sessions:
        # Idle means: nothing has crossed the tunnel for `limit`. An SA that
        # never carried a packet counts only once it is older than `limit`,
        # so a client that just connected is never reaped.
        idle = s_["last_use"] if s_["last_use"] is not None else s_["age_s"]
        if idle is not None and idle >= limit:
            print(s_["id"])
elif mode == "--ids":
    want = sys.argv[2]
    for s in sessions:
        if s["user"] == want:
            print(s["id"])
elif mode == "--who":
    if not sessions:
        print("nobody is connected")
        sys.exit(0)
    print(f"{'USER':<16} {'FROM':<18} {'VPN ADDRESS':<34} {'UP':<8} STATE")
    for s in sorted(sessions, key=lambda x: x["user"]):
        print(f"{s['user']:<16} {s['peer']:<18} {s['vips']:<34} "
              f"{s['age']:<8} {s['state']}")
    users = {s["user"] for s in sessions}
    print(f"\n{len(sessions)} session(s), {len(users)} distinct login(s)")
    if len(sessions) > len(users):
        print("note: a login with more than one session means either several "
              "devices share it,\n      or a stale session was left behind.")

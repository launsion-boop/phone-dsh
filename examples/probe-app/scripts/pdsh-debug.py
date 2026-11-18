#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mac-side client of the DEBUG-only debug channel (spec/dev/debug-channel.md, docs/debug-channel.md).

  pdsh-debug.py info | bots | devices | logs [voice|status] [-n 100]
  pdsh-debug.py chat "<prompt>" [--bot ID] [--wait 120] [--approve allow|deny]
  pdsh-debug.py turn [--wait 60]          continue waiting for the last chat
  pdsh-debug.py approvals [--bot ID]      pending approval cards
  pdsh-debug.py approve --bot ID [--deny] [--row ROW]
  pdsh-debug.py connect DEVICE            scan and connect a BLE device (id or name)
  pdsh-debug.py create-bot NAME           a plain unbound Bot (for testing delete/chat)
  pdsh-debug.py delete-bot ID [ID...] [--full]
  pdsh-debug.py grants [DEVICE] | grant DEVICE TOOL... [--revoke]
  pdsh-debug.py link DEVICE TOOL [JSON-ARGS]
  pdsh-debug.py raw METHOD PATH [JSON]

The phone is found with `xcrun devicectl` (CoreDevice tunnel address); the per-launch token is read from
the app's Documents/debug-channel.json over devicectl. Override with PDSH_DEBUG_UDID, PDSH_DEBUG_HOST,
PDSH_DEBUG_TOKEN. The app must be a Debug build in the foreground. Standard library only.
"""
import argparse, json, os, re, subprocess, sys, tempfile, time, urllib.request, urllib.error

BUNDLE = "com.tono.phonedsh.probe"
PORT = 47099


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def udid():
    if os.environ.get("PDSH_DEBUG_UDID"):
        return os.environ["PDSH_DEBUG_UDID"]
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "l.json")
        sh("xcrun", "devicectl", "list", "devices", "--json-output", out)
        found = []
        for dev in json.load(open(out)).get("result", {}).get("devices", []):
            u = dev.get("hardwareProperties", {}).get("udid", "")
            # A physical device UDID looks like 00008160-00023D1C2240000A; simulators use a UUID.
            if dev.get("hardwareProperties", {}).get("platform") == "iOS" and re.fullmatch(r"[0-9A-F]{8}-[0-9A-F]{16}", u) \
               and dev.get("connectionProperties", {}).get("tunnelState") == "connected":
                found.append(u)
        if len(found) == 1:
            return found[0]
        if found:
            sys.exit("several connected devices %s; set PDSH_DEBUG_UDID" % found)
    sys.exit("no iOS device found; set PDSH_DEBUG_UDID")


def endpoint():
    host, token = os.environ.get("PDSH_DEBUG_HOST"), os.environ.get("PDSH_DEBUG_TOKEN")
    port = PORT
    cache = os.path.join(tempfile.gettempdir(), "pdsh-debug-endpoint.json")
    if not (host and token) and os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 600:
        c = json.load(open(cache)); host, token, port = c["host"], c["token"], c["port"]
        try:  # still valid?
            call(host, port, token, "GET", "/info", None, timeout=4); return host, port, token
        except (Exception, SystemExit):      # stale token after an app relaunch, or the phone moved
            host = token = None
    if not host:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "d.json")
            sh("xcrun", "devicectl", "device", "info", "details", "--device", udid(), "--json-output", out)
            host = json.load(open(out))["result"]["connectionProperties"]["tunnelIPAddress"]
    if not token:
        with tempfile.TemporaryDirectory() as d:
            dest = os.path.join(d, "t.json")
            r = sh("xcrun", "devicectl", "device", "copy", "from", "--device", udid(), "--domain-type", "appDataContainer",
                   "--domain-identifier", BUNDLE, "--source", "Documents/debug-channel.json", "--destination", dest)
            if not os.path.exists(dest):
                sys.exit("cannot read the token (is the Debug app installed and was it launched in the foreground?)\n" + r.stderr[-300:])
            c = json.load(open(dest)); token, port = c["token"], c["port"]
    json.dump({"host": host, "token": token, "port": port}, open(cache, "w"))
    os.chmod(cache, 0o600)
    return host, port, token


def call(host, port, token, method, path, body, timeout=300):
    url = "http://[%s]:%d%s" % (host, port, path) if ":" in host else "http://%s:%d%s" % (host, port, path)
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"x-pdsh-debug-token": token, "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit("HTTP %d: %s" % (e.code, e.read().decode()[:300]))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd")
    p.add_argument("args", nargs="*")
    p.add_argument("--bot"); p.add_argument("--wait", type=float); p.add_argument("--approve")
    p.add_argument("--deny", action="store_true"); p.add_argument("--row"); p.add_argument("--full", action="store_true")
    p.add_argument("--revoke", action="store_true"); p.add_argument("-n", type=int, default=100)
    a = p.parse_args()
    t0 = time.time()
    host, port, token = endpoint()
    def go(m, path, body=None): return call(host, port, token, m, path, body)
    c = a.cmd
    if c == "info": out = go("GET", "/info")
    elif c == "bots": out = go("GET", "/bots")
    elif c == "devices": out = go("GET", "/devices")
    elif c == "logs": out = go("GET", "/logs?name=%s&lines=%d" % (a.args[0] if a.args else "voice", a.n)); print("\n".join(out["lines"])); return
    elif c == "chat":
        body = {"prompt": a.args[0], "wait": a.wait or 120}
        if a.bot: body["bot"] = a.bot
        if a.approve: body["approve"] = a.approve
        out = go("POST", "/chat", body)
    elif c == "turn": out = go("GET", "/turn?wait=%s" % (a.wait or 60))
    elif c == "approvals": out = go("GET", "/approvals" + ("?bot=" + a.bot if a.bot else ""))
    elif c == "approve": out = go("POST", "/approve", {"bot": a.bot, "decision": "deny" if a.deny else "allow", **({"row": a.row} if a.row else {})})
    elif c == "connect": out = go("POST", "/devices/connect", {"device": a.args[0]})
    elif c == "create-bot": out = go("POST", "/bots/create", {"name": a.args[0] if a.args else "debug-bot"})
    elif c == "delete-bot": out = go("POST", "/bots/delete", {"ids": a.args, "full": a.full})
    elif c == "grants": out = go("GET", "/grants" + ("?device=" + a.args[0] if a.args else ""))
    elif c == "grant": out = go("POST", "/grants", {"device": a.args[0], "tools": a.args[1:], "enabled": not a.revoke})
    elif c == "link": out = go("POST", "/link", {"device": a.args[0], "name": a.args[1], "args": json.loads(a.args[2]) if len(a.args) > 2 else {}})
    elif c == "raw": out = go(a.args[0], a.args[1], json.loads(a.args[2]) if len(a.args) > 2 else None)
    else: p.error("unknown command")
    print(json.dumps(out, ensure_ascii=False, indent=2))
    print("# %.1fs" % (time.time() - t0), file=sys.stderr)


if __name__ == "__main__":
    main()

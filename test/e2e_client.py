#!/usr/bin/env python3
"""End-to-end: start the Lua bridge (fake Resolve) under luajit, drive it with the upstream MCP
client exactly as the server would, check every operation and every refusal, then shut it down.
usage: e2e_client.py <mcp-repo-root>"""
import json
import os
import pathlib
import random
import secrets
import socket
import subprocess
import sys
import tempfile
import time

BRIDGE_DIR = pathlib.Path(__file__).resolve().parents[1]
MCP_ROOT = sys.argv[1]
sys.path.insert(0, MCP_ROOT)

home = pathlib.Path.home()
port = random.randint(49700, 49900)
tmp = pathlib.Path(tempfile.mkdtemp(prefix="resolve-bridge-"))
cfg_path = tmp / "bridge.json"
config = {
    "host": "127.0.0.1", "port": port, "token": secrets.token_urlsafe(32), "auth_clock_skew_seconds": 60,
    "allowed_media_roots": [str(home)], "allowed_output_roots": [str(home / "Movies")],
}
cfg_path.write_text(json.dumps(config, indent=2))
os.chmod(cfg_path, 0o600)
os.environ["DAVINCI_RESOLVE_BRIDGE_CONFIG"] = str(cfg_path)
os.environ["DAVINCI_RESOLVE_BRIDGE"] = "1"

runner = ["luajit", str(BRIDGE_DIR / "test/run_fake.lua"), str(cfg_path)]
if os.environ.get("BRIDGE_CONSOLE_MODE") == "1":
    runner.append("console")
    if os.environ.get("BRIDGE_INSTALL_DIR"):
        runner.append(os.environ["BRIDGE_INSTALL_DIR"])
proc = subprocess.Popen(runner, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
deadline = time.time() + 10
while time.time() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            break
    except OSError:
        time.sleep(0.1)
else:
    proc.kill()
    print(proc.stdout.read())
    raise SystemExit("bridge never opened its port")

from src.utils import resolve_bridge as _bridge  # noqa: E402
from src.utils import resolve_bridge_client as client  # noqa: E402

passed = 0
def ok(name, cond, extra=""):
    global passed
    if cond:
        passed += 1
    else:
        print("FAIL", name, extra)
        raise SystemExit(1)

def raw_request(payload_line: bytes) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        s.sendall(payload_line)
        return json.loads(s.makefile("rb").readline())

try:
    proxy = client.connect(require_enabled=True)
    t = proxy._transport
    health = t.request("health", {})
    ok("health", health["connected"] is True and health["edition"] == "free" and health["runtime"] == "lua" and health["bridge_version"], health)
    ok("health ops", set(client.REQUIRED_BRIDGE_OPERATIONS) <= set(health["operations"]))

    ok("GetVersionString", proxy.GetVersionString() == "21.1.0.fake")
    pm = proxy.GetProjectManager()
    project = pm.GetCurrentProject()
    ok("project name", project.GetName() == "bridge-test")
    tl = project.GetCurrentTimeline()
    ok("timeline name", tl.GetName() == "TL 1")
    ok("track count", tl.GetTrackCount("video") == 2)
    items = tl.GetItemListInTrack("video", 1)
    ok("items", len(items) == 2 and items[0].GetName() == "Item A" and items[1].GetDuration() == 120, items)
    ok("SetName", tl.SetName("Renamed") is True and tl.GetName() == "Renamed")
    ok("AddMarker args", tl.AddMarker(86500, "Blue", "hook", "note", 1) is True)
    ok("dict return", tl.GetSetting()["timelineFrameRate"] == "24")
    ok("false return", proxy.OpenPage("fusion") is False)
    big = proxy.GetBigList()
    ok("large reply survives a full send buffer", len(big) == 2000 and len(big[0]) == 300 and len(big[-1]) == 300, len(big))
    ok("hasattr known", hasattr(tl, "GetName"))
    ok("hasattr unknown", not hasattr(tl, "DefinitelyNotAMethod"))

    attr = t.request("get_attribute", {"target": "resolve", "name": "EXPORT_AAF"})
    ok("get_attribute value", attr["kind"] == "value" and attr["value"] == "AAF", attr)
    ok("get_attribute callable", t.request("get_attribute", {"target": "resolve", "name": "GetVersionString"})["kind"] == "callable")
    ok("get_attribute absent", t.request("get_attribute", {"target": "resolve", "name": "NOPE"})["kind"] == "absent")

    lm = t.request("list_media", {})
    paths = [c["file_path"] for c in lm["clips"]]
    ok("list_media policy", paths[0].endswith("A001.mov") and paths[1] == "<outside-allowed-roots>", paths)
    gt = t.request("get_timeline", {})
    ok("get_timeline tracks", len(gt["tracks"]) == 4 and gt["start_timecode"] == "01:00:00:00", gt)
    ok("list_timelines", t.request("list_timelines", {})["timelines"][0]["name"] == "Renamed")
    ok("list_projects", "bridge-test" in t.request("list_projects", {})["projects"])
    ok("list_projects db scrub", "IpAddress" not in t.request("list_projects", {})["database"])
    ok("get_render_formats", t.request("get_render_formats", {})["current"]["codec"] == "H265")
    ok("save_project", t.request("save_project", {})["saved"] is True)
    ok("set_current_timeline", t.request("set_current_timeline", {"timeline_name": "Renamed"})["current_timeline"] == "Renamed")

    # refusals
    def refused(name, op, args, code):
        try:
            t.request(op, args)
        except client.BridgeCallError as exc:
            got = getattr(exc, "code", None) or str(exc.args[0]).split(":")[0]
            ok(name, got == code, exc.args)
        else:
            ok(name, False, "no error raised")
    refused("stale handle", "call", {"target": "h:nope:1", "method": "GetName", "args": []}, "stale_handle")
    refused("private method", "call", {"target": "resolve", "method": "__class__", "args": []}, "method_not_allowed")
    refused("unknown op", "format_disk", {}, "operation_not_allowed")
    refused("missing timeline", "set_current_timeline", {"timeline_name": "ghost"}, "not_found")
    refused("resolve raised", "call", {"target": "current_timeline", "method": "Explode", "args": []}, "resolve_raised")
    refused("no such method", "call", {"target": "resolve", "method": "Nope", "args": []}, "capability_unavailable")

    # wire-level: replay, bad signature, missing protocol, oversize
    payload = {"protocol": "1.0", "id": "replay-1", "timestamp": int(time.time()), "nonce": "replay_" + secrets.token_hex(8), "operation": "health", "arguments": {}}
    payload["signature"] = _bridge.sign_request(config["token"], payload)
    line = (json.dumps(payload, separators=(",", ":")) + "\n").encode()
    ok("raw ok", raw_request(line)["ok"] is True)
    ok("replay refused", raw_request(line)["error"]["code"] == "replayed_request")
    bad = dict(payload, nonce="other_" + secrets.token_hex(8))
    ok("bad signature", raw_request((json.dumps(bad, separators=(",", ":")) + "\n").encode())["error"]["code"] == "unauthorized")
    ok("no protocol", raw_request(b'{"id":"x","operation":"health"}\n')["error"]["code"] == "protocol_mismatch")
    ok("invalid json", raw_request(b"{nope\n")["error"]["code"] == "invalid_json")
    ok("oversize", raw_request(b"{" + b" " * (_bridge.MAX_REQUEST_BYTES + 10) + b"}\n")["error"]["code"] == "request_too_large")

    released = t.request("release_handles", {})
    ok("release all", released["all"] is True and released["released"] > 0, released)
    stop = t.request("shutdown", {})
    ok("shutdown", stop["stopping"] is True and stop["mode"] == "exit", stop)
finally:
    try:
        out, _ = proc.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    print("--- bridge output ---")
    print(out.strip())

ok("bridge exited", proc.returncode == 0, proc.returncode)
print(f"e2e: {passed} checks passed")

#!/usr/bin/env python3
"""Generate protocol fixtures with the upstream client's own code, so the Lua side is tested
against exactly what davinci-resolve-mcp signs and sends. Usage: make_fixtures.py <mcp-src-utils-dir> <out.json>"""
import hashlib
import hmac
import json
import sys
import time
import uuid

sys.path.insert(0, sys.argv[1])
import resolve_bridge as _bridge  # noqa: E402  (upstream module, provides canonical_request/sign_request)

TOKEN = "fixture-token-0123456789abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOP"

cases = [
    {"operation": "health", "arguments": {}},
    {"operation": "call", "arguments": {"target": "resolve", "method": "GetVersionString", "args": []}},
    {"operation": "call", "arguments": {"target": "h:deadbeef:7", "method": "SetName", "args": ["Tímelíne ✓ 🎬", 1.5, -0.0, 1e-07, 123456789012, True, False, None]}},
    {"operation": "call", "arguments": {"target": "project", "method": "SetSetting", "args": ["timelineFrameRate", "29.97"]}},
    {"operation": "call", "arguments": {"z": 1, "a": {"nested": [{"b": 2, "a": 1}, []], "quote\"back\\slash": "tab\tnl\n/"}, "method": "X", "target": "resolve"}},
    {"operation": "list_methods", "arguments": {"target": "current_timeline"}},
    {"operation": "release_handles", "arguments": {"handles": ["h:1:1", "h:1:2"]}},
]

out = []
for c in cases:
    payload = {
        "protocol": _bridge.PROTOCOL_VERSION,
        "id": str(uuid.uuid4()),
        "timestamp": int(time.time()),
        "nonce": "n0nce_" + uuid.uuid4().hex,
        "operation": c["operation"],
        "arguments": c["arguments"],
    }
    payload["signature"] = _bridge.sign_request(TOKEN, payload)
    wire = json.dumps(payload, separators=(",", ":")) + "\n"
    out.append({
        "wire": wire,
        "canonical": _bridge.canonical_request(payload).decode("utf-8"),
        "signature": payload["signature"],
        "timestamp": payload["timestamp"],
    })

vectors = {
    "sha256_abc": hashlib.sha256(b"abc").hexdigest(),
    "sha256_empty": hashlib.sha256(b"").hexdigest(),
    "sha256_long": hashlib.sha256(b"a" * 1000).hexdigest(),
    "hmac_fox": hmac.new(b"key", b"The quick brown fox jumps over the lazy dog", hashlib.sha256).hexdigest(),
    "hmac_long_k": hmac.new(b"k" * 100, b"msg", hashlib.sha256).hexdigest(),
}
json.dump({"token": TOKEN, "cases": out, "vectors": vectors}, open(sys.argv[2], "w"), indent=1)
print("wrote", len(out), "cases to", sys.argv[2])

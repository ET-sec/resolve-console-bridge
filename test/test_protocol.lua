-- Protocol unit test: run with `luajit test/test_protocol.lua test/fixtures.json` from the bridge dir.
local here = arg[0]:match("^(.*)/test/[^/]+$") or "."
package.path = here .. "/lib/?.lua;" .. here .. "/gen/?.lua;" .. package.path
local json = require("json_raw")
local sha = require("sha256")

local function read(path) local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s end
local fixtures = json.value(assert(json.parse(read(arg[1] or (here .. "/test/fixtures.json")))))

local fails, total = 0, 0
local function check(name, got, want)
  total = total + 1
  if got ~= want then
    fails = fails + 1
    print("FAIL " .. name)
    print("  want: " .. tostring(want))
    print("  got:  " .. tostring(got))
  end
end

-- hash vectors
local v = fixtures.vectors
check("sha256(abc)", sha.sha256("abc"), v.sha256_abc)
check("sha256(empty)", sha.sha256(""), v.sha256_empty)
check("sha256(a*1000)", sha.sha256(string.rep("a", 1000)), v.sha256_long)
check("hmac fox", sha.hmac_sha256("key", "The quick brown fox jumps over the lazy dog"), v.hmac_fox)
check("hmac long key", sha.hmac_sha256(string.rep("k", 100), "msg"), v.hmac_long_k)
check("digest_equal same", sha.digest_equal(v.hmac_fox, v.hmac_fox), true)
check("digest_equal diff", sha.digest_equal(v.hmac_fox, v.hmac_long_k), false)

-- canonical form and signatures for every fixture the upstream client produced
for i = 1, fixtures.cases.n do
  local c = fixtures.cases[i]
  local node, err = json.parse(c.wire)
  check("parse case " .. i, node ~= nil, true)
  if node then
    local canon = json.canonical(node, "signature")
    check("canonical case " .. i, canon, c.canonical)
    check("signature case " .. i, sha.hmac_sha256(fixtures.token, canon), c.signature)
    -- round trip: value() then encode() must be valid JSON that parses back to the same canonical form
    local val = json.value(node)
    local re = json.encode(val)
    local node2 = assert(json.parse(re))
    check("re-encode case " .. i, json.canonical(node2, "signature"), c.canonical)
  end
end

-- bridge authentication on a real fixture: valid, replayed, tampered, stale
local bridge = require("bridge")
local case = fixtures.cases[1]
local node = assert(json.parse(case.wire))
local nonces = bridge.new_nonces(60)
check("auth ok", bridge.authenticate(node, fixtures.token, 60, nonces, case.timestamp), nil)
check("auth replay", bridge.authenticate(node, fixtures.token, 60, nonces, case.timestamp), "replayed_request")
check("auth stale", bridge.authenticate(node, fixtures.token, 60, bridge.new_nonces(60), case.timestamp + 61), "stale_request")
check("auth wrong token", bridge.authenticate(node, fixtures.token .. "x", 60, bridge.new_nonces(60), case.timestamp), "unauthorized")
local tampered = assert(json.parse((case.wire:gsub('"operation":"health"', '"operation":"shutdown"'))))
check("auth tampered", bridge.authenticate(tampered, fixtures.token, 60, bridge.new_nonces(60), case.timestamp), "unauthorized")
local with_token = assert(json.parse((case.wire:gsub('^{', '{"token":"x",'))))
check("auth token on wire", bridge.authenticate(with_token, fixtures.token, 60, bridge.new_nonces(60), case.timestamp), "unauthorized")

-- encoder edge cases
check("encode empty object", json.encode(json.object({})), "{}")
check("encode empty array", json.encode(json.array({})), "[]")
check("encode nested", json.encode({ b = { 1, 2 }, a = "x" }), '{"a":"x","b":[1,2]}')
check("encode unicode", json.encode("é🎬"), '"\\u00e9\\ud83c\\udfac"')
check("encode del", json.encode("\127"), '"\\u007f"')
check("encode float", json.encode(1.5), "1.5")
check("encode int", json.encode(86400), "86400")
check("encode null", json.encode(json.null), "null")

print(string.format("%d checks, %d failed", total, fails))
os.exit(fails == 0 and 0 or 1)

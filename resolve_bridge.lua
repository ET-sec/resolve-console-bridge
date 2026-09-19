-- Resolve Console bridge: entry point.
--
-- Paste one line into Workspace > Console inside DaVinci Resolve (the installer prints it for you):
--   macOS, Linux:  dofile(os.getenv("HOME") .. "/.config/davinci-resolve-mcp/console-bridge/resolve_bridge.lua")
--   Windows:       dofile(os.getenv("USERPROFILE") .. "/.config/davinci-resolve-mcp/console-bridge/resolve_bridge.lua")
--
-- The Console's Lua has ffi, bit, jit, bmd, os (no execute), loadfile and dofile, but no io, require,
-- package or debug (measured on free 21.1.0.14). This file supplies a minimal module loader and file
-- helpers so the bridge modules load unchanged.
--
-- Overrides, set as globals before the dofile line (the tests use them, and so can anyone running
-- straight from a checkout instead of the installed copy):
--   RESOLVE_BRIDGE_DIR     directory holding lib/ and gen/
--   RESOLVE_BRIDGE_CONFIG  path to bridge.json (default: ~/.config/davinci-resolve-mcp/bridge.json,
--                          the same file the davinci-resolve-mcp client reads)
local G = _G
-- USERPROFILE first on Windows, HOME first elsewhere: the same order Python's Path.home() uses on
-- the MCP client side, so both ends open the same bridge.json even when a Windows box sets HOME.
local jit_ = rawget(G, "jit")
local IS_WINDOWS = jit_ ~= nil and jit_.os == "Windows"
local HOME = (IS_WINDOWS and os.getenv("USERPROFILE")) or os.getenv("HOME") or os.getenv("USERPROFILE") or ""
local BRIDGE_DIR = rawget(G, "RESOLVE_BRIDGE_DIR") or (HOME .. "/.config/davinci-resolve-mcp/console-bridge")
local CONFIG_PATH = rawget(G, "RESOLVE_BRIDGE_CONFIG") or (HOME .. "/.config/davinci-resolve-mcp/bridge.json")
-- ljsocket stays cached on purpose: its ffi.cdef declarations live for the life of the Lua state.
local MODULES = { "bridge", "json_raw", "sha256", "api_methods" }

-- module loader (Console has no require/package)
if type(G.package) ~= "table" then
  G.package = { loaded = {}, path = "", cpath = "", config = "/\n;\n?\n!\n-\n", preload = {} }
end
if type(G.package.loaded) ~= "table" then G.package.loaded = {} end
local loaded = G.package.loaded
for _, name in ipairs({ "ffi", "bit", "jit", "string", "table", "math", "os", "coroutine", "io", "debug" }) do
  if loaded[name] == nil and rawget(G, name) ~= nil then loaded[name] = rawget(G, name) end
end

local function file_exists(path)
  local bmd = rawget(G, "bmd")
  if bmd and type(bmd.fileexists) == "function" then
    local ok, v = pcall(bmd.fileexists, path)
    if ok then return v and true or false end
  end
  local io_ = rawget(G, "io")
  if io_ then
    local f = io_.open(path, "r")
    if f then f:close(); return true end
  end
  return false
end

if type(G.require) ~= "function" then
  G.require = function(name)
    local v = loaded[name]
    if v ~= nil then return v end
    for _, sub in ipairs({ "/lib/", "/gen/" }) do
      local path = BRIDGE_DIR .. sub .. name .. ".lua"
      if file_exists(path) then
        local chunk, err = loadfile(path)
        if not chunk then error("resolve-bridge: cannot load " .. path .. ": " .. tostring(err)) end
        local result = chunk(name)
        if result == nil then result = true end
        loaded[name] = result
        return result
      end
    end
    error("resolve-bridge: module '" .. name .. "' not found under " .. BRIDGE_DIR .. " (run the installer, or set RESOLVE_BRIDGE_DIR)")
  end
end

local function fresh()
  for _, name in ipairs(MODULES) do loaded[name] = nil end
end

-- run
fresh()
local bridge = require("bridge")
local mode = bridge.main({ config_path = CONFIG_PATH })
while mode == "reload" do
  fresh()
  bridge = require("bridge")
  mode = bridge.main({ config_path = CONFIG_PATH })
end
print("[resolve-bridge] finished: " .. tostring(mode))

-- Resolve Console bridge: a Lua implementation of the davinci-resolve-mcp in-app bridge.
--
-- Runs INSIDE DaVinci Resolve. The free edition kept its Lua interpreter when Blackmagic moved
-- Python scripting to Studio in 21.1 (2026-09-08), and Workspace > Console still executes Lua there.
-- This module listens on 127.0.0.1 and answers the same wire protocol as scripts/resolve_bridge.py in
-- samuelgursky/davinci-resolve-mcp v4.7.9, so the MCP server drives Resolve unchanged:
--   * one newline-terminated JSON request per TCP connection, one JSON reply line
--   * HMAC-SHA256 over the canonical request (sorted keys, compact, ASCII) with the shared token
--   * integer timestamp within auth_clock_skew_seconds, one-use nonce retained for 2x the skew
--   * explicit operation allowlist, session-scoped object handles, private names refused
--
-- Entry: resolve_bridge.lua (Console dofile) supplies a module loader and calls M.main().
local json = require("json_raw")
local sha = require("sha256")
local socket = require("ljsocket")

local M = {}

M.VERSION = "1.0.0"
M.PROTOCOL_VERSION = "1.0"
M.SURFACE_VERSION = "1.0"
M.MAX_REQUEST_BYTES = 1048576
M.PREAUTH_READ_TIMEOUT_S = 5.0
M.OPERATION_TIMEOUT_S = 300.0
M.MAX_HANDLES = 4096
M.DEFAULT_MAX_ITEMS = 2000
M.POLL_SECONDS = 0.02

local READ_OPERATIONS = { "health", "list_projects", "get_project", "list_timelines", "get_timeline", "list_media", "get_render_formats" }
local WRITE_OPERATIONS = { "save_project", "set_current_timeline" }
local PROXY_OPERATIONS = { "call", "release_handles", "list_methods", "get_attribute" }
local LIFECYCLE_OPERATIONS = { "shutdown", "reload" }
local ROOT_NAMES = { resolve = true, project_manager = true, project = true, media_pool = true, current_timeline = true }

local function sorted_copy(...)
  local out = {}
  for _, list in ipairs({ ... }) do for _, v in ipairs(list) do out[#out + 1] = v end end
  table.sort(out, json.bytewise_less)
  return json.array(out)
end

-- environment

local function global(name) return rawget(_G, name) end

local jit_ = global("jit")
local OS_NAME = (jit_ and jit_.os) or "Unknown" -- "OSX", "Linux" or "Windows" under LuaJIT
local IS_WINDOWS = OS_NAME == "Windows"
M.OS_NAME = OS_NAME

-- USERPROFILE first on Windows, HOME first elsewhere: the same order Python's Path.home() uses on
-- the MCP client side, so both ends open the same bridge.json even when a Windows box sets HOME.
local function home_dir()
  if IS_WINDOWS then return os.getenv("USERPROFILE") or os.getenv("HOME") or "" end
  return os.getenv("HOME") or os.getenv("USERPROFILE") or ""
end
M.home_dir = home_dir

-- File access: the Console's Lua has no io library, but it has ffi, so libc stdio stands in.
local function get_ffi()
  local ffi = global("ffi")
  if ffi == nil then
    local ok, mod = pcall(require, "ffi")
    if ok then ffi = mod end
  end
  if ffi == nil then return nil end
  pcall(ffi.cdef, [[
    typedef struct rcb_FILE rcb_FILE;
    rcb_FILE* fopen(const char* path, const char* mode);
    size_t fread(void* buf, size_t size, size_t n, rcb_FILE* f);
    size_t fwrite(const void* buf, size_t size, size_t n, rcb_FILE* f);
    int fclose(rcb_FILE* f);
  ]])
  return ffi
end

local function read_file(path)
  local io_ = global("io")
  if io_ then
    local f, err = io_.open(path, "rb")
    if not f then return nil, err end
    local s = f:read("*a")
    f:close()
    return s
  end
  local ffi = get_ffi()
  if ffi then
    local ok, f = pcall(function() return ffi.C.fopen(path, "rb") end)
    if not ok then return nil, "fopen is not reachable through ffi in this Lua host: " .. tostring(f) end
    if f == nil then return nil, "cannot open " .. path end
    local chunks, buf = {}, ffi.new("char[?]", 65536)
    while true do
      local n = tonumber(ffi.C.fread(buf, 1, 65536, f))
      if n == 0 then break end
      chunks[#chunks + 1] = ffi.string(buf, n)
    end
    ffi.C.fclose(f)
    return table.concat(chunks)
  end
  return nil, "no file reader available in this Lua environment"
end
M.read_file = read_file

local function write_file(path, content, mode)
  mode = mode or "wb"
  local io_ = global("io")
  if io_ then
    local f = io_.open(path, mode)
    if not f then return false end
    f:write(content)
    f:close()
    return true
  end
  local ffi = get_ffi()
  if ffi then
    local ok, f = pcall(function() return ffi.C.fopen(path, mode) end)
    if not ok or f == nil then return false end
    ffi.C.fwrite(content, 1, #content, f)
    ffi.C.fclose(f)
    return true
  end
  return false
end
M.write_file = write_file

-- The log sits beside the config so there is one place to look on every platform.
local LOG_PATH = home_dir() .. "/.config/davinci-resolve-mcp/console-bridge.log"
local function log_line(msg)
  local line = os.date("%Y-%m-%d %H:%M:%S ") .. tostring(msg)
  print("[resolve-bridge] " .. tostring(msg))
  write_file(LOG_PATH, line .. "\n", "ab")
end
M.log = log_line

local sleep
do
  local bmd = global("bmd")
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi then ffi = global("ffi"); ok_ffi = ffi ~= nil end
  if bmd and type(bmd.wait) == "function" then
    sleep = function(s) bmd.wait(s) end
  elseif ok_ffi and IS_WINDOWS then
    pcall(ffi.cdef, [[ void Sleep(uint32_t ms); ]])
    sleep = function(s) ffi.C.Sleep(math.floor(s * 1000)) end
  elseif ok_ffi then
    pcall(ffi.cdef, [[ int usleep(unsigned int usec); ]])
    sleep = function(s) ffi.C.usleep(math.floor(s * 1000000)) end
  else
    sleep = function(s) local t = os.clock() + s; while os.clock() < t do end end
  end
end
M.sleep = sleep

local function get_resolve()
  local r = global("resolve")
  if r ~= nil then return r, "global" end
  local bmd = global("bmd")
  if bmd and type(bmd.scriptapp) == "function" then
    local ok, v = pcall(bmd.scriptapp, "Resolve")
    if ok and v ~= nil then return v, "bmd.scriptapp" end
  end
  local fu = global("fusion") or global("fu")
  if fu and type(fu.GetResolve) == "function" then
    local ok, v = pcall(fu.GetResolve, fu)
    if ok and v ~= nil then return v, "fusion:GetResolve" end
  end
  if type(global("Resolve")) == "function" then
    local ok, v = pcall(global("Resolve"))
    if ok and v ~= nil then return v, "Resolve()" end
  end
  return nil, "no resolve object in this Lua environment"
end
M.get_resolve = get_resolve

-- config

local function is_list(v) return type(v) == "table" and (v.n ~= nil or #v > 0 or next(v) == nil) end

function M.load_config(path)
  local raw, err = read_file(path)
  if not raw then return nil, "cannot read bridge config " .. path .. ": " .. tostring(err) end
  local node, perr = json.parse(raw)
  if not node then return nil, "bridge config is not valid JSON: " .. tostring(perr) end
  if node.t ~= "object" then return nil, "bridge config must be an object" end
  local cfg = json.value(node)
  local host = cfg.host or "127.0.0.1"
  if host ~= "127.0.0.1" then return nil, "bridge host must be 127.0.0.1, never a routable interface" end
  if type(cfg.token) ~= "string" or #cfg.token < 43 then return nil, "bridge token is missing or too short (need >= 43 chars)" end
  local port = cfg.port
  if type(port) ~= "number" or port ~= math.floor(port) or port < 1024 or port > 65535 then return nil, "bridge port is missing or not in 1024..65535 (run the installer to write a config)" end
  local skew = cfg.auth_clock_skew_seconds or 60
  if type(skew) ~= "number" or skew ~= math.floor(skew) or skew < 10 or skew > 300 then return nil, "auth_clock_skew_seconds must be 10..300" end
  local media_roots, output_roots = {}, {}
  if is_list(cfg.allowed_media_roots) then for i = 1, (cfg.allowed_media_roots.n or #cfg.allowed_media_roots) do media_roots[i] = cfg.allowed_media_roots[i] end end
  if is_list(cfg.allowed_output_roots) then for i = 1, (cfg.allowed_output_roots.n or #cfg.allowed_output_roots) do output_roots[i] = cfg.allowed_output_roots[i] end end
  if #media_roots == 0 then media_roots = { home_dir() } end
  if #output_roots == 0 then output_roots = { home_dir() .. (OS_NAME == "OSX" and "/Movies" or "/Videos") } end
  return { host = "127.0.0.1", port = port, token = cfg.token, auth_clock_skew_seconds = skew,
           media_roots = media_roots, output_roots = output_roots }
end

-- path policy

-- Windows paths arrive from Resolve with backslashes and a drive letter whose case varies, so on
-- Windows both sides of the comparison are folded to forward slashes and lower case first.
local function normalize_path(p)
  if type(p) ~= "string" or p == "" then return nil end
  if p:sub(1, 1) == "~" then p = home_dir() .. p:sub(2) end
  if IS_WINDOWS then p = p:gsub("\\", "/"):lower() end
  p = p:gsub("/+", "/")
  if p:find("/%.%./") or p:find("/%.%.$") or p:sub(1, 3) == "../" or p == ".." then return nil end
  if #p > 1 then p = p:gsub("/$", "") end
  return p
end

local function under_roots(path, roots)
  local p = normalize_path(path)
  if not p then return false end
  for _, root in ipairs(roots) do
    local r = normalize_path(root)
    if r and (p == r or p:sub(1, #r + 1) == r .. "/") then return true end
  end
  return false
end

-- errors

local OperationError = {}
OperationError.__index = OperationError
local function op_error(code, message, details)
  return setmetatable({ code = code, message = message, details = details }, OperationError)
end
local function is_op_error(e) return type(e) == "table" and getmetatable(e) == OperationError end

-- object model helpers

local function is_object(v)
  local tv = type(v)
  if tv == "userdata" then return true end
  if tv == "table" then
    local mt = getmetatable(v)
    return mt ~= nil and mt.__resolve_object == true
  end
  return false
end

local function type_name(obj)
  local ok, s = pcall(tostring, obj)
  if ok and type(s) == "string" then
    local name = s:match("^([%w_]+)")
    if name and name ~= "userdata" and name ~= "table" then return name end
  end
  return "Object"
end

local function member(obj, name)
  local ok, v = pcall(function() return obj[name] end)
  if ok then return v end
  return nil
end

local function invoke(obj, name, args, n)
  local fn = member(obj, name)
  if type(fn) ~= "function" then
    return nil, op_error("capability_unavailable", type_name(obj) .. " has no callable '" .. name .. "' in this Resolve build")
  end
  local packed = { pcall(fn, obj, unpack(args, 1, n or #args)) }
  if not packed[1] then
    return nil, op_error("resolve_raised", "Resolve raised while running " .. name .. ": " .. tostring(packed[2]):sub(1, 200))
  end
  return packed[2], nil, packed.n
end

local function call_ok(obj, name, ...)
  local v, err = invoke(obj, name, { ... }, select("#", ...))
  if err then error(err, 0) end
  return v
end

-- operations

local Ops = {}
Ops.__index = Ops

function M.new_ops(resolve, config, lifecycle)
  local self = setmetatable({}, Ops)
  self.resolve = resolve
  self.config = config
  self.lifecycle = lifecycle
  self.max_items = M.DEFAULT_MAX_ITEMS
  self.handles = {}
  self.handle_order = {}
  self.handle_count = 0
  self.handle_counter = 0
  math.randomseed(os.time() + math.floor((os.clock() % 1) * 1000000))
  self.session = string.format("%08x", math.random(0, 0x7fffffff))
  self.truncation = {}
  self.api_methods = nil
  local ok, tbl = pcall(require, "api_methods")
  if ok and type(tbl) == "table" then self.api_methods = tbl end
  return self
end

function Ops:operations()
  return sorted_copy(READ_OPERATIONS, WRITE_OPERATIONS, PROXY_OPERATIONS, LIFECYCLE_OPERATIONS)
end

function Ops:project_manager()
  local pm = call_ok(self.resolve, "GetProjectManager")
  if pm == nil then error(op_error("resolve_not_ready", "Resolve has no project manager yet"), 0) end
  return pm
end

function Ops:project()
  local p = call_ok(self:project_manager(), "GetCurrentProject")
  if p == nil then error(op_error("no_project", "no Resolve project is currently open"), 0) end
  return p
end

function Ops:timeline(arguments)
  local project = self:project()
  local name = arguments.timeline_name
  if name == nil or name == json.null or name == "" then
    local tl = call_ok(project, "GetCurrentTimeline")
    if tl == nil then error(op_error("no_timeline", "no current timeline is selected"), 0) end
    return tl
  end
  local matches = {}
  local count = tonumber(call_ok(project, "GetTimelineCount")) or 0
  for i = 1, count do
    local c = call_ok(project, "GetTimelineByIndex", i)
    if c ~= nil and call_ok(c, "GetName") == name then matches[#matches + 1] = c end
  end
  if #matches == 0 then error(op_error("not_found", "timeline '" .. tostring(name) .. "' was not found"), 0) end
  if #matches > 1 then error(op_error("ambiguous_locator", "more than one timeline is named '" .. tostring(name) .. "'"), 0) end
  return matches[1]
end

-- handles

function Ops:mint(obj, shape)
  self.handle_counter = self.handle_counter + 1
  local h = string.format("h:%s:%d", self.session, self.handle_counter)
  self.handles[h] = { obj = obj, shape = shape or "?" }
  self.handle_order[#self.handle_order + 1] = h
  self.handle_count = self.handle_count + 1
  while self.handle_count > M.MAX_HANDLES do
    local oldest = table.remove(self.handle_order, 1)
    if self.handles[oldest] then self.handles[oldest] = nil; self.handle_count = self.handle_count - 1 end
  end
  return h
end

function Ops:shape_of(target)
  if type(target) == "string" and ROOT_NAMES[target] then return target end
  local e = type(target) == "string" and self.handles[target] or nil
  return e and e.shape or "?"
end

function Ops:named_root(name)
  if name == "resolve" then return self.resolve end
  local pm = self:project_manager()
  if name == "project_manager" then return pm end
  local project = call_ok(pm, "GetCurrentProject")
  if project == nil then error(op_error("no_project", "no Resolve project is currently open"), 0) end
  if name == "project" then return project end
  if name == "media_pool" then return call_ok(project, "GetMediaPool") end
  if name == "current_timeline" then
    local tl = call_ok(project, "GetCurrentTimeline")
    if tl == nil then error(op_error("no_timeline", "no current timeline is selected"), 0) end
    return tl
  end
  error(op_error("invalid_arguments", "unknown root object '" .. tostring(name) .. "'"), 0)
end

function Ops:resolve_target(target)
  if type(target) ~= "string" or target == "" then
    error(op_error("invalid_arguments", "target must be a root name or a bridge handle"), 0)
  end
  if ROOT_NAMES[target] then return self:named_root(target) end
  if target:sub(1, 2) == "h:" then
    local e = self.handles[target]
    if e then return e.obj end
    error(op_error("stale_handle", "that handle is no longer held by the bridge; re-fetch the object and retry",
      { hint = "handles are session-scoped and bounded; a restart or heavy enumeration evicts them" }), 0)
  end
  error(op_error("invalid_arguments", "target must be one of resolve, project_manager, project, media_pool, current_timeline or a bridge-issued handle"), 0)
end

-- value encoding: Resolve return value -> JSON-safe, minting handles for live objects

-- Resolve's Lua tables carry a "__flags" bookkeeping key; it is not data and must not leak or
-- turn a list into a dict.
local function is_meta_key(k) return k == "__flags" end

local function table_kind(t)
  local n = 0
  for k in pairs(t) do if not is_meta_key(k) then n = n + 1 end end
  if n == 0 then return "empty", 0 end
  local len = #t
  if len == n then
    for i = 1, len do if t[i] == nil then return "dict", n end end
    return "list", len
  end
  return "dict", n
end

function Ops:note_truncation(total, kind, depth, shape)
  if total <= self.max_items then return end
  self.truncation[#self.truncation + 1] = json.object({
    shape = shape, kind = kind, depth = depth, returned = self.max_items, total = total, dropped = total - self.max_items,
  })
end

function Ops:encode(value, depth, shape)
  depth = depth or 0
  local tv = type(value)
  if value == nil or tv == "boolean" or tv == "number" or tv == "string" then return value end
  if depth > 6 then return tostring(value) end
  if is_object(value) then
    return json.object({ __handle__ = self:mint(value, shape), __type__ = type_name(value), __shape__ = shape })
  end
  if tv == "table" then
    local kind, n = table_kind(value)
    if kind == "list" then
      self:note_truncation(n, "list", depth, shape)
      local out = json.array({})
      local limit = math.min(n, self.max_items)
      for i = 1, limit do out[i] = self:encode(value[i], depth + 1, shape) end
      out.n = limit
      return out
    end
    self:note_truncation(n, "dict", depth, shape)
    local out = json.object({})
    local count = 0
    for k, v in pairs(value) do
      if not is_meta_key(k) then
        count = count + 1
        if count > self.max_items then break end
        out[tostring(k)] = self:encode(v, depth + 1, shape)
      end
    end
    return out
  end
  return tostring(value)
end

function Ops:encoded(value, shape)
  self.truncation = {}
  local encoded = self:encode(value, 0, shape)
  local reply = json.object({ value = encoded })
  if #self.truncation > 0 then
    local dropped = 0
    local containers = json.array({})
    for i, row in ipairs(self.truncation) do
      dropped = dropped + row.dropped
      if i <= 8 then containers[i] = row end
    end
    reply.truncated = json.object({
      dropped = dropped, limit = self.max_items, containers = containers,
      hint = "This reply is INCOMPLETE. The value is not evidence of how many items exist. Re-read in smaller pieces, or count from the object itself rather than from this list.",
    })
    self.truncation = {}
  end
  return reply
end

-- argument decoding: JSON value -> Lua value, rehydrating bridge handles
function Ops:decode(value)
  if value == json.null then return nil end
  if type(value) == "table" then
    local mt = getmetatable(value)
    if mt and mt.__jsontype == "object" then
      if value.__handle__ ~= nil then return self:resolve_target(value.__handle__) end
      local out = {}
      for k, v in pairs(value) do out[k] = self:decode(v) end
      return out
    end
    local out = {}
    local n = value.n or #value
    for i = 1, n do out[i] = self:decode(value[i]) end
    return out
  end
  return value
end

-- read operations

function Ops:op_health()
  local pm = self:project_manager()
  local project = call_ok(pm, "GetCurrentProject")
  local product = tostring(call_ok(self.resolve, "GetProductName") or "")
  return json.object({
    connected = true,
    product = product,
    version = call_ok(self.resolve, "GetVersionString"),
    edition = product:lower():find("studio", 1, true) and "studio" or "free",
    current_page = call_ok(self.resolve, "GetCurrentPage"),
    current_project = project ~= nil and call_ok(project, "GetName") or json.null,
    surface_version = M.SURFACE_VERSION,
    bridge_version = M.VERSION,
    platform = OS_NAME,
    session = self.session,
    operations = self:operations(),
    read_operations = sorted_copy(READ_OPERATIONS),
    write_operations = sorted_copy(WRITE_OPERATIONS),
    lifecycle_available = self.lifecycle ~= nil,
    runtime = "lua",
    policy = json.object({ media_roots = json.array(self.config.media_roots), output_roots = json.array(self.config.output_roots), max_items = self.max_items }),
  })
end

function Ops:op_list_projects()
  local pm = self:project_manager()
  local current = call_ok(pm, "GetCurrentProject")
  local database = call_ok(pm, "GetCurrentDatabase")
  local db = json.object({})
  if type(database) == "table" then for k, v in pairs(database) do if k ~= "IpAddress" then db[tostring(k)] = v end end end
  local projects = json.array({})
  local list = call_ok(pm, "GetProjectListInCurrentFolder")
  if type(list) == "table" then for i = 1, math.min(#list, self.max_items) do projects[i] = list[i] end end
  return json.object({
    folder = call_ok(pm, "GetCurrentFolder"),
    projects = projects,
    current_project = current ~= nil and call_ok(current, "GetName") or json.null,
    database = db,
  })
end

function Ops:op_get_project()
  local project = self:project()
  local tl = call_ok(project, "GetCurrentTimeline")
  return json.object({
    name = call_ok(project, "GetName"),
    timeline_count = tonumber(call_ok(project, "GetTimelineCount")) or 0,
    current_timeline = tl ~= nil and call_ok(tl, "GetName") or json.null,
  })
end

function Ops:op_list_timelines()
  local project = self:project()
  local count = tonumber(call_ok(project, "GetTimelineCount")) or 0
  local timelines = json.array({})
  for i = 1, math.min(count, self.max_items) do
    local tl = call_ok(project, "GetTimelineByIndex", i)
    if tl ~= nil then
      timelines[#timelines + 1] = json.object({
        index = i, name = call_ok(tl, "GetName"), start_frame = call_ok(tl, "GetStartFrame"), end_frame = call_ok(tl, "GetEndFrame"),
      })
    end
  end
  return json.object({ timelines = timelines, total = count, truncated = count > self.max_items })
end

function Ops:op_get_timeline(arguments)
  local tl = self:timeline(arguments)
  local tracks = json.array({})
  for _, track_type in ipairs({ "video", "audio", "subtitle" }) do
    local count = tonumber(call_ok(tl, "GetTrackCount", track_type)) or 0
    for i = 1, count do
      tracks[#tracks + 1] = json.object({
        type = track_type, index = i,
        name = call_ok(tl, "GetTrackName", track_type, i),
        enabled = call_ok(tl, "GetIsTrackEnabled", track_type, i),
        locked = call_ok(tl, "GetIsTrackLocked", track_type, i),
      })
    end
  end
  return json.object({
    name = call_ok(tl, "GetName"), start_frame = call_ok(tl, "GetStartFrame"), end_frame = call_ok(tl, "GetEndFrame"),
    start_timecode = call_ok(tl, "GetStartTimecode"), tracks = tracks,
  })
end

function Ops:op_list_media()
  local pool = call_ok(self:project(), "GetMediaPool")
  local root = call_ok(pool, "GetRootFolder")
  if root == nil or root == false then error(op_error("operation_failed", "Resolve returned failure from GetRootFolder"), 0) end
  local clips = json.array({})
  local pending, seen = { root }, {}
  while #pending > 0 and #clips < self.max_items do
    local folder = table.remove(pending)
    local unique = tostring(call_ok(folder, "GetUniqueId"))
    if not seen[unique] then
      seen[unique] = true
      local list = call_ok(folder, "GetClipList")
      if type(list) == "table" then
        for _, clip in ipairs(list) do
          if #clips >= self.max_items then break end
          local props = call_ok(clip, "GetClipProperty")
          if type(props) ~= "table" then props = {} end
          local raw_path = tostring(props["File Path"] or "")
          clips[#clips + 1] = json.object({
            name = call_ok(clip, "GetName"),
            file_path = under_roots(raw_path, self.config.media_roots) and raw_path or "<outside-allowed-roots>",
            duration = props["Duration"], fps = props["FPS"], resolution = props["Resolution"],
          })
        end
      end
      local subs = call_ok(folder, "GetSubFolderList")
      if type(subs) == "table" then for _, sf in ipairs(subs) do pending[#pending + 1] = sf end end
    end
  end
  return json.object({ clips = clips, truncated = #clips >= self.max_items })
end

function Ops:op_get_render_formats()
  local project = self:project()
  local formats = call_ok(project, "GetRenderFormats")
  local current = call_ok(project, "GetCurrentRenderFormatAndCodec")
  return json.object({
    formats = type(formats) == "table" and self:encode(formats, 0, "project.GetRenderFormats") or json.object({}),
    current = type(current) == "table" and self:encode(current, 0, "project.GetCurrentRenderFormatAndCodec") or json.object({}),
  })
end

-- write operations

function Ops:op_save_project()
  self:project()
  local ok = call_ok(self:project_manager(), "SaveProject")
  if ok == false or ok == nil then error(op_error("operation_failed", "Resolve returned failure from SaveProject"), 0) end
  return json.object({ saved = true })
end

function Ops:op_set_current_timeline(arguments)
  local name = arguments.timeline_name
  if type(name) ~= "string" or name:match("^%s*$") then error(op_error("invalid_arguments", "timeline_name is required"), 0) end
  local tl = self:timeline({ timeline_name = name })
  local ok = call_ok(self:project(), "SetCurrentTimeline", tl)
  if ok == false or ok == nil then error(op_error("operation_failed", "Resolve returned failure from SetCurrentTimeline"), 0) end
  return json.object({ current_timeline = call_ok(tl, "GetName") })
end

-- proxy operations

function Ops:op_call(arguments)
  local method = arguments.method
  if type(method) ~= "string" or method == "" then error(op_error("invalid_arguments", "method must be a non-empty string"), 0) end
  if method:sub(1, 1) == "_" then error(op_error("method_not_allowed", "private and dunder attributes are not reachable"), 0) end
  local target_key = arguments.target
  if target_key == nil or target_key == json.null then target_key = "resolve" end
  local target = self:resolve_target(target_key)
  if target == nil then error(op_error("not_found", "the requested object is not available right now"), 0) end
  local raw_args = arguments.args
  if raw_args == nil or raw_args == json.null then raw_args = json.array({}) end
  local mt = getmetatable(raw_args)
  if type(raw_args) ~= "table" or (mt and mt.__jsontype == "object") then error(op_error("invalid_arguments", "args must be a list"), 0) end
  local n = raw_args.n or #raw_args
  if n > 64 then error(op_error("invalid_arguments", "too many arguments"), 0) end
  local args = {}
  for i = 1, n do args[i] = self:decode(raw_args[i]) end
  local result, err = invoke(target, method, args, n)
  if err then error(err, 0) end
  return self:encoded(result, self:shape_of(target_key) .. "." .. method)
end

function Ops:op_list_methods(arguments)
  local target_key = arguments.target
  if target_key == nil or target_key == json.null then target_key = "resolve" end
  local target = self:resolve_target(target_key)
  local tname = type_name(target)
  local names = {}
  if self.api_methods then
    local list = self.api_methods[tname]
    if list then
      for _, m in ipairs(list) do names[#names + 1] = m end
    else
      local seen = {}
      for _, methods in pairs(self.api_methods) do
        for _, m in ipairs(methods) do if not seen[m] then seen[m] = true; names[#names + 1] = m end end
      end
    end
  end
  if type(target) == "table" then
    for k, v in pairs(target) do
      if type(k) == "string" and type(v) == "function" and k:sub(1, 1) ~= "_" then names[#names + 1] = k end
    end
  end
  table.sort(names, json.bytewise_less)
  return json.object({ type = tname, shape = self:shape_of(target_key), methods = json.array(names) })
end

function Ops:op_get_attribute(arguments)
  local name = arguments.name
  if type(name) ~= "string" or name == "" then error(op_error("invalid_arguments", "name must be a non-empty string"), 0) end
  if name:sub(1, 1) == "_" then error(op_error("method_not_allowed", "private and dunder attributes are not reachable"), 0) end
  local target_key = arguments.target
  if target_key == nil or target_key == json.null then target_key = "resolve" end
  local target = self:resolve_target(target_key)
  local ok, value = pcall(function() return target[name] end)
  if not ok then error(op_error("resolve_raised", "reading " .. name .. " raised: " .. tostring(value):sub(1, 200)), 0) end
  if value == nil then
    return json.object({ kind = "absent" })
  end
  if type(value) == "function" then return json.object({ kind = "callable" }) end
  local reply = self:encoded(value, self:shape_of(target_key) .. "." .. name)
  reply.kind = "value"
  return reply
end

function Ops:op_release_handles(arguments)
  local handles = arguments.handles
  if handles == nil or handles == json.null then
    local count = self.handle_count
    self.handles, self.handle_order, self.handle_count = {}, {}, 0
    return json.object({ released = count, all = true })
  end
  local mt = getmetatable(handles)
  if type(handles) ~= "table" or (mt and mt.__jsontype == "object") then error(op_error("invalid_arguments", "handles must be a list"), 0) end
  local released = 0
  for i = 1, (handles.n or #handles) do
    local h = handles[i]
    if self.handles[h] then self.handles[h] = nil; self.handle_count = self.handle_count - 1; released = released + 1 end
  end
  return json.object({ released = released, all = false, held = self.handle_count })
end

function Ops:lifecycle_stop(mode)
  if self.lifecycle == nil then
    error(op_error("capability_unavailable", "this bridge was started without a lifecycle owner, so it cannot stop itself; quit the script inside Resolve instead"), 0)
  end
  local outcome = self.lifecycle(mode) or {}
  local reply = json.object({ stopping = true, mode = mode })
  for k, v in pairs(outcome) do reply[k] = v end
  return reply
end
function Ops:op_shutdown() return self:lifecycle_stop("exit") end
function Ops:op_reload() return self:lifecycle_stop("reload") end

function Ops:dispatch(operation, arguments)
  local fn = self["op_" .. tostring(operation)]
  local allowed = false
  for _, list in ipairs({ READ_OPERATIONS, WRITE_OPERATIONS, PROXY_OPERATIONS, LIFECYCLE_OPERATIONS }) do
    for _, name in ipairs(list) do if name == operation then allowed = true end end
  end
  if not allowed or type(fn) ~= "function" then
    error(op_error("operation_not_allowed", "operation '" .. tostring(operation) .. "' is not exposed by this bridge", { available = self:operations() }), 0)
  end
  return fn(self, arguments)
end

-- authentication

local function node_get(obj_node, key)
  for _, p in ipairs(obj_node.pairs) do if p.key == key then return p.value end end
  return nil
end

local Nonces = {}
Nonces.__index = Nonces
function M.new_nonces(skew) return setmetatable({ retention = skew * 2, seen = {}, count = 0 }, Nonces) end
function Nonces:check_and_add(nonce, now)
  local cutoff = now - self.retention
  if self.count > 5000 then
    for k, t in pairs(self.seen) do if t < cutoff then self.seen[k] = nil; self.count = self.count - 1 end end
  end
  -- hard cap: only a holder of the token can fill this store with signed requests, so a flood past
  -- the cap is dropped wholesale rather than growing without bound inside Resolve
  if self.count > 50000 then self.seen = {}; self.count = 0 end
  local t = self.seen[nonce]
  if t and t >= cutoff then return false end
  if not t then self.count = self.count + 1 end
  self.seen[nonce] = now
  return true
end

function M.authenticate(node, token, skew, nonces, now)
  now = now or os.time()
  if node.t ~= "object" then return "invalid_request" end
  local proto = node_get(node, "protocol")
  if not proto or proto.t ~= "string" or proto.value ~= M.PROTOCOL_VERSION then return "protocol_mismatch" end
  if node_get(node, "token") then return "unauthorized" end
  local ts, nonce, sig = node_get(node, "timestamp"), node_get(node, "nonce"), node_get(node, "signature")
  if not ts or ts.t ~= "number" or ts.raw:find("[%.eE]") then return "unauthorized" end
  if not nonce or nonce.t ~= "string" or not nonce.value:match("^[A-Za-z0-9_%-]+$") or #nonce.value < 16 or #nonce.value > 128 then return "unauthorized" end
  if not sig or sig.t ~= "string" or not sig.value:match("^[0-9a-f]+$") or #sig.value ~= 64 then return "unauthorized" end
  local expected = sha.hmac_sha256(token, json.canonical(node, "signature"))
  if not sha.digest_equal(expected, sig.value) then return "unauthorized" end
  if math.abs(now - ts.value) > skew then return "stale_request" end
  if not nonces:check_and_add(nonce.value, now) then return "replayed_request" end
  return nil
end

-- request processing

local function error_reply(id, code, message, details)
  local e = json.object({ code = code })
  if message then e.message = tostring(message):sub(1, 300) end
  if type(details) == "table" then e.details = details end
  return json.object({ id = id, ok = false, error = e })
end

function M.process(line, ops, config, nonces)
  local node, perr = json.parse(line)
  if not node then return error_reply(json.null, "invalid_json") end
  local id = json.null
  if node.t == "object" then
    local idn = node_get(node, "id")
    if idn and idn.t == "string" then id = idn.value end
  end
  local auth_error = M.authenticate(node, config.token, config.auth_clock_skew_seconds, nonces)
  if auth_error then return error_reply(id, auth_error) end
  local opn = node_get(node, "operation")
  local argn = node_get(node, "arguments")
  if not opn or opn.t ~= "string" then return error_reply(id, "invalid_request") end
  local arguments = json.object({})
  if argn then
    if argn.t ~= "object" then return error_reply(id, "invalid_request") end
    arguments = json.value(argn)
  end
  local ok, result = pcall(function() return ops:dispatch(opn.value, arguments) end)
  if not ok then
    if is_op_error(result) then return error_reply(id, result.code, result.message, result.details) end
    return error_reply(id, "operation_failed", tostring(result))
  end
  return json.object({ id = id, ok = true, result = result })
end

-- socket server

local function send_all(client, data)
  local sent = 0
  local deadline = os.time() + 10
  while sent < #data do
    local n, err, num = client:send(data:sub(sent + 1))
    if n then sent = sent + n
    elseif err == "timeout" or num == 11 or num == 35 or num == 10035 then
      -- would-block (EAGAIN on Linux, 35 on macOS, WSAEWOULDBLOCK on Windows): the kernel send
      -- buffer is full, wait for the client to drain it
      if os.time() > deadline then return false end
      sleep(0.005)
    else return false end
  end
  return true
end

local function read_line(client, timeout_s)
  local buf = {}
  local total = 0
  local started = os.time()
  while true do
    local chunk, err = client:receive(65536)
    if chunk and #chunk > 0 then
      buf[#buf + 1] = chunk
      total = total + #chunk
      if chunk:find("\n", 1, true) then break end
      if total > M.MAX_REQUEST_BYTES then return nil, "request_too_large" end
    elseif chunk == nil and err == "timeout" then
      if os.time() - started > timeout_s then return nil, "timeout" end
      sleep(0.005)
    else
      break
    end
  end
  local s = table.concat(buf)
  if s == "" then return nil, "empty" end
  local nl = s:find("\n", 1, true)
  if nl then s = s:sub(1, nl - 1) end
  if #s > M.MAX_REQUEST_BYTES then return nil, "request_too_large" end
  return s
end

--- Serve until shutdown/reload. Returns the stop mode ("exit" or "reload").
function M.serve(resolve, config, opts)
  opts = opts or {}
  local stop_mode = nil
  local ops = M.new_ops(resolve, config, function(mode) stop_mode = mode; return { runtime = "lua" } end)
  local nonces = M.new_nonces(config.auth_clock_skew_seconds)

  local info = assert(socket.find_first_address(config.host, config.port))
  local server = assert(socket.create(info.family, info.socket_type, info.protocol))
  assert(server:set_blocking(false))
  if not IS_WINDOWS then server:set_option("reuseaddr", true) end
  local bound, berr = server:bind(info)
  if not bound then
    server:close()
    error("cannot bind 127.0.0.1:" .. config.port .. ": " .. tostring(berr))
  end
  assert(server:listen())
  log_line("bridge " .. M.VERSION .. " listening on 127.0.0.1:" .. config.port .. " (session " .. ops.session .. ", " .. OS_NAME .. ")")
  if opts.on_ready then opts.on_ready(ops) end

  local served = 0
  while stop_mode == nil do
    local client = server:accept()
    if client then
      client:set_blocking(false)
      -- a client that gives up and closes before the reply is written must not deliver SIGPIPE to
      -- the Resolve process; Linux sends with MSG_NOSIGNAL, Windows has no SIGPIPE, macOS needs this
      if OS_NAME == "OSX" then pcall(client.set_option, client, "nosigpipe", true) end
      local line, rerr = read_line(client, M.PREAUTH_READ_TIMEOUT_S)
      local reply
      if line then
        reply = M.process(line, ops, config, nonces)
      elseif rerr == "request_too_large" then
        reply = error_reply(json.null, "request_too_large")
      end
      if reply then send_all(client, json.encode(reply) .. "\n") end
      client:close()
      served = served + 1
    else
      sleep(opts.poll_seconds or M.POLL_SECONDS)
    end
    if opts.should_stop and opts.should_stop() then stop_mode = "exit" end
  end
  server:close()
  log_line("stopped (" .. stop_mode .. ") after " .. served .. " requests")
  return stop_mode
end

function M.main(opts)
  opts = opts or {}
  local config, cerr = M.load_config(opts.config_path)
  if not config then log_line("config error: " .. tostring(cerr)); return nil, cerr end
  local resolve, how = opts.resolve, "supplied"
  if resolve == nil then resolve, how = get_resolve() end
  if resolve == nil then log_line("no Resolve object: " .. tostring(how)); return nil, how end
  log_line("resolve object via " .. tostring(how) .. ": " .. tostring(resolve))
  local mode = M.serve(resolve, config, opts)
  return mode
end

return M

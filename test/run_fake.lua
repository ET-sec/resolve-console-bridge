-- Runs the bridge under plain LuaJIT against a fake Resolve object model. Used by test/e2e_client.py.
-- usage: luajit test/run_fake.lua <bridge.json> [console [bridge-dir]]
--   "console" simulates Resolve's Console Lua: no io, require, package or debug; bmd helpers present;
--   the bridge is started through the real entry script exactly as it is inside Resolve.
--   bridge-dir points the entry script at an installed copy instead of this checkout.
local here = arg[0]:match("^(.*)/test/[^/]+$") or "."
local CONSOLE_MODE = arg[2] == "console"
local real_io = io
if not CONSOLE_MODE then
  package.path = here .. "/lib/?.lua;" .. here .. "/gen/?.lua;" .. package.path
end

local HOME = os.getenv("HOME") or ""
local function obj(name, methods)
  return setmetatable(methods, { __resolve_object = true, __tostring = function() return name .. " (0xfake)" end })
end

local item_a = obj("TimelineItem", { GetName = function() return "Item A" end, GetStart = function() return 86400 end, GetDuration = function() return 240 end })
local item_b = obj("TimelineItem", { GetName = function() return "Item B" end, GetStart = function() return 86640 end, GetDuration = function() return 120 end })

local timeline = obj("Timeline", {
  name = "TL 1",
  GetName = function(self) return self.name end,
  SetName = function(self, n) self.name = n; return true end,
  GetStartFrame = function() return 86400 end,
  GetEndFrame = function() return 90000 end,
  GetStartTimecode = function() return "01:00:00:00" end,
  GetTrackCount = function(_, t) return t == "video" and 2 or 1 end,
  GetTrackName = function(_, t, i) return t .. " " .. i end,
  GetIsTrackEnabled = function() return true end,
  GetIsTrackLocked = function() return false end,
  GetItemListInTrack = function(_, t, i) if t == "video" and i == 1 then return { item_a, item_b } end return {} end,
  GetSetting = function(_, k) if k then return "24" end return { timelineFrameRate = "24", timelineResolutionWidth = "1080" } end,
  AddMarker = function(_, frame, color, name, note, duration) return frame == 86500 and color == "Blue" end,
  Explode = function() error("simulated Resolve failure") end,
})

local clip = obj("MediaPoolItem", {
  GetName = function() return "A001.mov" end,
  GetClipProperty = function() return { ["File Path"] = HOME .. "/Movies/A001.mov", Duration = "00:00:10:00", FPS = 24, Resolution = "1920x1080" } end,
})
local hidden = obj("MediaPoolItem", {
  GetName = function() return "secret.mov" end,
  GetClipProperty = function() return { ["File Path"] = "/somewhere/else/outside.mov", Duration = "00:00:01:00", FPS = 24, Resolution = "1920x1080" } end,
})
local folder = obj("Folder", {
  GetUniqueId = function() return "root" end,
  GetName = function() return "Master" end,
  GetClipList = function() return { clip, hidden } end,
  GetSubFolderList = function() return {} end,
})
local pool = obj("MediaPool", { GetRootFolder = function() return folder end })

local project = obj("Project", {
  GetName = function() return "bridge-test" end,
  GetTimelineCount = function() return 1 end,
  GetTimelineByIndex = function(_, i) if i == 1 then return timeline end return nil end,
  GetCurrentTimeline = function() return timeline end,
  SetCurrentTimeline = function() return true end,
  GetMediaPool = function() return pool end,
  GetRenderFormats = function() return { mp4 = "MP4", mov = "QuickTime" } end,
  GetCurrentRenderFormatAndCodec = function() return { format = "mp4", codec = "H265" } end,
  GetSetting = function(_, k) if k then return "24" end return { timelineFrameRate = "24" } end,
})

local pm = obj("ProjectManager", {
  GetCurrentProject = function() return project end,
  GetCurrentDatabase = function() return { DbType = "Disk", DbName = "Local Database", IpAddress = "127.0.0.1" } end,
  GetCurrentFolder = function() return "" end,
  GetProjectListInCurrentFolder = function() return { "Untitled Project", "bridge-test" } end,
  SaveProject = function() return true end,
})

local resolve = obj("Resolve", {
  GetProjectManager = function() return pm end,
  GetProductName = function() return "DaVinci Resolve" end,
  GetVersionString = function() return "21.1.0.fake" end,
  GetCurrentPage = function() return "edit" end,
  OpenPage = function(_, p) return p == "edit" or p == "color" end,
  -- 3000 strings of 300 bytes: the encoded reply is far larger than any platform's default socket
  -- send buffer, so send_all must survive a would-block mid-reply (truncation caps it at 2000 items)
  GetBigList = function() local t = {} for i = 1, 3000 do t[i] = string.rep("x", 300) end return t end,
  EXPORT_AAF = "AAF",
})

if CONSOLE_MODE then
  -- what the Console gives a script, and nothing else
  _G.bmd = {
    readstring = function(path) local f = real_io.open(path, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end,
    writestring = function(path, s) local f = real_io.open(path, "w"); if not f then return false end f:write(s); f:close(); return true end,
    fileexists = function(path) local f = real_io.open(path, "r"); if f then f:close(); return true end return false end,
    wait = function(s) local ffi = _G.ffi; ffi.cdef("int usleep(unsigned int);"); ffi.C.usleep(math.floor(s * 1000000)) end,
  }
  _G.ffi, _G.bit, _G.jit = require("ffi"), require("bit"), require("jit")
  pcall(_G.ffi.cdef, "int usleep(unsigned int);")
  _G.resolve = resolve
  local bridge_dir = arg[3] or here
  _G.RESOLVE_BRIDGE_DIR = bridge_dir
  _G.RESOLVE_BRIDGE_CONFIG = arg[1]
  _G.io, _G.require, _G.package, _G.debug = nil, nil, nil, nil
  local os_ = os
  _G.os = { getenv = os_.getenv, time = os_.time, clock = os_.clock, date = os_.date, tmpname = os_.tmpname }
  dofile(bridge_dir .. "/resolve_bridge.lua")
else
  local bridge = require("bridge")
  local mode = bridge.main({ config_path = arg[1], resolve = resolve, poll_seconds = 0.005 })
  print("fake bridge finished:", mode)
end

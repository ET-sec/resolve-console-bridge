# How it works

The README covers installing and using the bridge. This page covers why it runs in the Console and
what it accepts and refuses on the wire.

## Why the Console

DaVinci Resolve 21.1 (released 2026-09-08) moved Python scripting to Studio. On the free edition:

- External scripting refuses a foreign process, as it did before.
- The Workspace > Scripts menu no longer lists `.py` files, and a Lua file launched from it
  executes nothing (measured on free 21.1.0.14 with a project open: no log line, no print).
- Workspace > Console still executes Lua. `dofile` of a file on disk works, and the script it
  loads is handed the live `resolve` object.

So the bridge runs there. It is the same idea as the Python in-app bridge that ships with
davinci-resolve-mcp for Resolve 21.0.x, rewritten in Lua because that is the interpreter free 21.1 still has.

## What the Console's Lua provides

What a script gets inside the Console on free 21.1.0.14, and what the entry script does about it:

| Present | Absent | Consequence |
|---|---|---|
| `ffi`, `bit`, `jit`, `bmd`, `os` (without `execute`), `loadfile`, `dofile` | `io`, `require`, `package`, `debug` | `resolve_bridge.lua` installs a small `require` that loads modules from the bridge folder with `loadfile`; file reads and writes go through libc `fopen` via `ffi` |
| `bmd.wait` | | Used for the poll sleep, so the loop never spins |
| `bmd.readstring`, `bmd.writestring` | | Serialize Lua tables; they are not file access |
| `ffi.cdef` | | A type declared twice in one Lua state is an error, so every declaration is wrapped in `pcall` and the socket module stays cached across restarts |

Resolve objects print as `Project (0x...)`, `Timeline (0x...)` and so on. That name selects the
per-class method list in `gen/api_methods.lua`, generated from Blackmagic's `DaVinciResolveScript.pyi`
and README for 21.1.0. Resolve's Lua tables carry a `__flags` bookkeeping key, stripped on encode so a
list stays a list.

## The wire

One TCP connection per request, on 127.0.0.1 and the port in `bridge.json`. The client sends one
newline-terminated JSON object; the bridge answers one JSON line and closes.

A request carries `protocol`, `id`, `timestamp`, `nonce`, `operation`, `arguments` and `signature`.
The signature is HMAC-SHA256 over the canonical form of the request without the signature field:
keys sorted, compact separators, ASCII-escaped, byte for byte what Python's
`json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=True)` produces. `lib/json_raw.lua`
keeps every number's wire literal through parsing so the canonical form can be re-emitted exactly.
`lib/sha256.lua` is a pure Lua SHA-256 and HMAC, checked against FIPS 180-4 and RFC 4231 vectors by
the protocol test.

A request is refused when any of these fails, in this order:

| Check | Error code |
|---|---|
| valid JSON object | `invalid_json`, `invalid_request` |
| `protocol` equals `1.0` | `protocol_mismatch` |
| no `token` field on the wire (the token never travels) | `unauthorized` |
| integer `timestamp`, well-formed `nonce` (16 to 128 URL-safe characters), 64 hex character `signature` | `unauthorized` |
| signature matches, compared in constant time | `unauthorized` |
| timestamp within `auth_clock_skew_seconds` of now | `stale_request` |
| nonce not seen within twice the skew window | `replayed_request` |
| request under 1 MiB | `request_too_large` |

A connection that sends nothing readable within five seconds is dropped.

## Operations

| Kind | Operations |
|---|---|
| read | `health`, `list_projects`, `get_project`, `list_timelines`, `get_timeline`, `list_media`, `get_render_formats` |
| write | `save_project`, `set_current_timeline` |
| proxy | `call`, `release_handles`, `list_methods`, `get_attribute` |
| lifecycle | `shutdown`, `reload` |

Anything else answers `operation_not_allowed` with the list above. The proxy operations are how the
MCP server reaches the rest of the scripting API, and through them everything the API can do is
reachable, deletes and exports included: `call` invokes a named method on a root object
(`resolve`, `project_manager`, `project`, `media_pool`, `current_timeline`) or on a handle the bridge
issued earlier. Names starting with an underscore are refused. At most 64 arguments per call.

Live Resolve objects in replies become handles of the form `h:<session>:<n>`. Handles are scoped to
the bridge session, capped at 4096 with the oldest evicted first, and a stale one answers
`stale_handle` with a hint to re-fetch. Lists and dictionaries in replies are capped at 2000 items;
a truncated reply is marked as truncated and names what was dropped.

`reload` re-reads the bridge modules from disk without touching the Resolve UI, which is how a
change is tested in place. `shutdown` stops the listener.

## Path policy

`bridge.json` holds two lists of folders. `list_media` returns a clip's file path only when it sits
under an allowed media root; otherwise the path comes back as `<outside-allowed-roots>`. That filter
applies to `list_media`; a proxy `call` returns what Resolve returns, and the bridge does not stop a
render or export from targeting a folder outside the output roots. Both root lists are reported in
`health` so the MCP server can apply its own checks on its side. The comparison is textual: a `..`
segment is rejected, a symlink is not resolved. On Windows both sides of the comparison are
folded to forward slashes and lower case first, because Resolve reports paths with backslashes and a
drive letter of varying case. The installer sets both lists to your home folder and its Movies (macOS)
or Videos (Windows, Linux) folder; edit the file to widen or narrow them.

## The config file

`bridge.json` lives where the davinci-resolve-mcp client already looks, `~/.config/davinci-resolve-mcp/`
under your home folder on every platform (`USERPROFILE` on Windows). The installer writes it readable
by your account only and never overwrites one that exists.

| Field | Meaning |
|---|---|
| `host` | Must be `127.0.0.1`. Any other value is refused at start. |
| `port` | Chosen at random in the dynamic range by the installer. Required; no default. |
| `token` | 43 or more URL-safe characters, generated on your machine. Shared with nothing but the MCP client on the same machine. |
| `auth_clock_skew_seconds` | Window for the request timestamp, 10 to 300. Default 60. |
| `allowed_media_roots` | Folders whose clip paths may be reported. |
| `allowed_output_roots` | Folders the MCP server may render into. |

The log is `console-bridge.log` beside it. Delete both, and the `console-bridge/` folder next to them,
to remove the bridge entirely.

## Timings

Measured on an Apple silicon laptop, free 21.1.0.14, with the bridge polling every 20 ms:

| Call | Time |
|---|---|
| `health` | 51 ms |
| `GetVersionString` | 45 ms |
| project name, timeline count and similar reads | 20 to 90 ms |
| `GetRenderPresetList` | 194 ms |
| `OpenPage` | 375 ms |

Resolve's UI stays responsive while the loop runs (about 13 percent of one core at that poll rate)
and a full 118 second 4K render queued through the bridge finished in 54 seconds on that machine.

## Files

| Path | Role |
|---|---|
| `resolve_bridge.lua` | Entry: module loader, config path, restart loop for `reload` |
| `lib/bridge.lua` | Listener, authentication, operations, handles, path policy |
| `lib/json_raw.lua` | JSON with canonical re-emission |
| `lib/sha256.lua` | SHA-256 and HMAC |
| `lib/ljsocket.lua` | FFI sockets, macOS, Linux and Windows (see LICENSE) |
| `gen/api_methods.lua` | Class to method-name table for `list_methods` |
| `guard/` | Claude Code hook refusing three upstream capabilities |
| `install.sh`, `install.ps1` | Copy into place, write the config, print the Console line |
| `test/` | Protocol suite, fake Resolve, end-to-end against the real MCP client |

## Platform notes

- Home folder: `USERPROFILE` first on Windows, `HOME` first elsewhere, the same order Python's
  `Path.home()` uses on the client side, so both ends open the same `bridge.json`.
- Sleep outside Resolve (tests only): `usleep` on macOS and Linux, `Sleep` on Windows. Inside Resolve
  `bmd.wait` is used everywhere.
- Sockets: `ffi.C` on macOS and Linux, `ws2_32` with `WSAStartup` on Windows, handled inside
  `lib/ljsocket.lua`.
- Line endings: the repository checks out with LF everywhere except `install.ps1`.

## If Blackmagic closes the Console

Blackmagic can remove Console scripting in any release. If the `dofile` line stops running after an
update, that is the first thing to suspect; the README will carry the notice.

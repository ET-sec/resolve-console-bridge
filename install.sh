#!/usr/bin/env bash
# Resolve Console bridge installer for macOS and Linux. Safe to run again after a git pull.
#
# What it does:
#   1. copies the bridge (resolve_bridge.lua, lib/, gen/, guard/) to ~/.config/davinci-resolve-mcp/console-bridge/
#   2. writes ~/.config/davinci-resolve-mcp/bridge.json if there is none yet: a fresh random token, a random
#      loopback port, and path policy roots for your home folder; the file is readable by you only
#   3. prints the one line to paste into Resolve's Console
# It does not edit your AI client's config or Resolve's own folders, and it does not need sudo.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/davinci-resolve-mcp"
DEST="$CONF_DIR/console-bridge"
CONFIG="${DAVINCI_RESOLVE_BRIDGE_CONFIG:-$CONF_DIR/bridge.json}"

for f in resolve_bridge.lua lib/bridge.lua lib/json_raw.lua lib/sha256.lua lib/ljsocket.lua gen/api_methods.lua guard/resolve-mcp-guard.py; do
  if [ ! -f "$SRC/$f" ]; then
    echo "install: $f is missing next to this script. Run it from a full checkout of the repository."
    exit 1
  fi
done

umask 077
mkdir -p "$DEST/lib" "$DEST/gen" "$DEST/guard"
chmod 700 "$CONF_DIR"
cp "$SRC/resolve_bridge.lua" "$DEST/"
cp "$SRC"/lib/*.lua "$DEST/lib/"
cp "$SRC"/gen/*.lua "$DEST/gen/"
cp "$SRC/guard/resolve-mcp-guard.py" "$DEST/guard/"
echo "install: bridge files copied to $DEST"

if [ -f "$CONFIG" ]; then
  if grep -q '"token"' "$CONFIG"; then
    echo "install: keeping the existing config at $CONFIG"
  else
    echo "install: $CONFIG exists but has no token. Move it aside and run this again."
    exit 1
  fi
else
  case "$(uname -s)" in
    Darwin) OUT="$HOME/Movies" ;;
    *)      OUT="$HOME/Videos" ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    # 32 random bytes as URL-safe base64 without padding: 43 characters, the same shape the MCP
    # project's own installer writes. The port is random in the dynamic range so nothing in this
    # repository names it.
    HOME_DIR="$HOME" OUT_DIR="$OUT" CONFIG_PATH="$CONFIG" python3 - <<'PY'
import json, os, secrets
cfg = {
    "host": "127.0.0.1",
    "port": 49152 + secrets.randbelow(16384),
    "token": secrets.token_urlsafe(32),
    "auth_clock_skew_seconds": 60,
    "allowed_media_roots": [os.environ["HOME_DIR"]],
    "allowed_output_roots": [os.environ["OUT_DIR"]],
}
with open(os.environ["CONFIG_PATH"], "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  elif command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
    PORT=$(( 49152 + ( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 16384 ) ))
    printf '{\n  "host": "127.0.0.1",\n  "port": %s,\n  "token": "%s",\n  "auth_clock_skew_seconds": 60,\n  "allowed_media_roots": ["%s"],\n  "allowed_output_roots": ["%s"]\n}\n' \
      "$PORT" "$TOKEN" "$HOME" "$OUT" > "$CONFIG"
  else
    echo "install: python3 or openssl is needed to generate the token, and neither is on PATH."
    exit 1
  fi
  echo "install: wrote a new config at $CONFIG (token generated on this machine)"
fi
chmod 600 "$CONFIG"

cat <<MSG

Done. Next, inside DaVinci Resolve with a project open: Workspace > Console, paste this line, press Enter.

  dofile(os.getenv("HOME") .. "/.config/davinci-resolve-mcp/console-bridge/resolve_bridge.lua")

You should see a line that starts with:  [resolve-bridge] bridge 1.0.0 listening
Paste the line again each time you open Resolve. The Console does not remember it.
MSG

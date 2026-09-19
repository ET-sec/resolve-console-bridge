# Resolve Console bridge installer for Windows. Safe to run again after a git pull.
# From PowerShell in the checkout folder:   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# What it does:
#   1. copies the bridge (resolve_bridge.lua, lib\, gen\, guard\) to %USERPROFILE%\.config\davinci-resolve-mcp\console-bridge\
#   2. writes %USERPROFILE%\.config\davinci-resolve-mcp\bridge.json if there is none yet: a fresh random token,
#      a random loopback port, and path policy roots for your user folder; the file is readable by you only
#   3. prints the one line to paste into Resolve's Console
# It does not edit your AI client's config or Resolve's own folders, and it does not need admin rights.
$ErrorActionPreference = "Stop"

$Src = $PSScriptRoot
$UserHome = $env:USERPROFILE
$ConfDir = Join-Path $UserHome ".config\davinci-resolve-mcp"
$Dest = Join-Path $ConfDir "console-bridge"
$Config = if ($env:DAVINCI_RESOLVE_BRIDGE_CONFIG) { $env:DAVINCI_RESOLVE_BRIDGE_CONFIG } else { Join-Path $ConfDir "bridge.json" }

foreach ($f in "resolve_bridge.lua", "lib\bridge.lua", "lib\json_raw.lua", "lib\sha256.lua", "lib\ljsocket.lua", "gen\api_methods.lua", "guard\resolve-mcp-guard.py") {
  if (-not (Test-Path (Join-Path $Src $f))) {
    throw "install: $f is missing next to this script. Run it from a full checkout of the repository."
  }
}

New-Item -ItemType Directory -Force -Path (Join-Path $Dest "lib"), (Join-Path $Dest "gen"), (Join-Path $Dest "guard") | Out-Null
Copy-Item (Join-Path $Src "resolve_bridge.lua") $Dest -Force
Copy-Item (Join-Path $Src "lib\*.lua") (Join-Path $Dest "lib") -Force
Copy-Item (Join-Path $Src "gen\*.lua") (Join-Path $Dest "gen") -Force
Copy-Item (Join-Path $Src "guard\resolve-mcp-guard.py") (Join-Path $Dest "guard") -Force
Write-Host "install: bridge files copied to $Dest"

if (Test-Path $Config) {
  if (Select-String -Path $Config -Pattern '"token"' -Quiet) {
    Write-Host "install: keeping the existing config at $Config"
  } else {
    throw "install: $Config exists but has no token. Move it aside and run this again."
  }
} else {
  # 32 random bytes as URL-safe base64 without padding: 43 characters, the same shape the MCP
  # project's own installer writes. The port is random in the dynamic range so nothing in this
  # repository names it.
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $tokenBytes = New-Object byte[] 32
  $rng.GetBytes($tokenBytes)
  $token = [Convert]::ToBase64String($tokenBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
  $portBytes = New-Object byte[] 2
  $rng.GetBytes($portBytes)
  $port = 49152 + ([BitConverter]::ToUInt16($portBytes, 0) % 16384)
  $homeFwd = $UserHome.Replace('\', '/')
  $cfg = [ordered]@{
    host = "127.0.0.1"
    port = $port
    token = $token
    auth_clock_skew_seconds = 60
    allowed_media_roots = @($homeFwd)
    allowed_output_roots = @("$homeFwd/Videos")
  }
  $json = ($cfg | ConvertTo-Json) + "`n"
  # UTF-8 without a byte order mark: both the Lua parser and the Python client expect plain JSON.
  [System.IO.File]::WriteAllText($Config, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "install: wrote a new config at $Config (token generated on this machine)"
}

# Only this user can read the token: drop inherited permissions, grant the current account alone.
# A volume without ACLs (exFAT, some network shares) makes icacls fail; say so instead of stopping.
$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& icacls $Config /inheritance:r /grant:r "${who}:M" | Out-Null
$ErrorActionPreference = $prev
if ($LASTEXITCODE -ne 0) {
  Write-Warning "install: could not restrict $Config to your account (icacls exit $LASTEXITCODE). Set its permissions by hand so only you can read it."
}

Write-Host ""
Write-Host "Done. Next, inside DaVinci Resolve with a project open: Workspace > Console, paste this line, press Enter."
Write-Host ""
Write-Host '  dofile(os.getenv("USERPROFILE") .. "/.config/davinci-resolve-mcp/console-bridge/resolve_bridge.lua")'
Write-Host ""
Write-Host "You should see a line that starts with:  [resolve-bridge] bridge 1.0.0 listening"
Write-Host "Paste the line again each time you open Resolve. The Console does not remember it."

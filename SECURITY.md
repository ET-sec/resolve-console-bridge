# Security

## Reporting

Use GitHub's private vulnerability reporting for anything that could expose a token, reach the
bridge from outside the machine, or make the bridge do something its config forbids:
[open a private report](https://github.com/ET-sec/resolve-console-bridge/security/advisories/new).
Do not file a public issue for a security finding. Reports are read by the maintainer; expect an
acknowledgment within seven days.

## What is in scope

- `resolve_bridge.lua` and everything under `lib/` and `gen/`: the listener, authentication, the
  operation allowlist, handles, and the path policy
- `install.sh` and `install.ps1`: token generation, file permissions, what gets copied where
- `guard/resolve-mcp-guard.py`: the Claude Code hook that refuses three upstream capabilities

## What is out of scope here

- davinci-resolve-mcp itself. Findings in the MCP server belong upstream at
  [samuelgursky/davinci-resolve-mcp](https://github.com/samuelgursky/davinci-resolve-mcp).
- DaVinci Resolve.
- Your AI client's own permission model.

## Design summary

The bridge binds 127.0.0.1 only and refuses any other host in its config. Every request carries an
HMAC-SHA256 signature over its canonical form, computed with a token the installer generates on
your machine and stores in a file only your account can read. Each request also carries an integer
timestamp that must fall within a short window and a nonce that is accepted once. The operation
set is a fixed allowlist, private attribute names are refused, object handles are scoped to the
session and bounded, and media paths outside the configured roots are not returned. The full
account is in [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).

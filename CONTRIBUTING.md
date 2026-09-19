# Contributing

Issues and pull requests are welcome. Two things about this repository are unusual and worth
knowing before you spend time on a change.

## One author on main

Every commit on `main` is authored, committed and co-authored by the maintainer, and a required
check (`authorship`) refuses anything else. Accepted pull requests are therefore applied by the
maintainer as their own commits, with credit to you by name and link in the commit message and in
the release notes. If that is not acceptable to you, say so in the pull request and we will talk
before any work is merged.

## Secret and personal-data scanning

The tracked `.gitleaks.toml` extends the default secret rules with pattern tripwires: absolute paths
into a named home folder, external drive paths, personal email addresses, phone numbers, and any
assigned bridge token. Continuous integration runs it on every push and pull request. If a scan
fails on your branch, fix the content; do not allowlist around it.

## Working on it

```bash
git clone https://github.com/ET-sec/resolve-console-bridge.git
cd resolve-console-bridge
git config core.hooksPath .githooks      # gitleaks before every commit, identity check before every push (public rules)
brew install luajit gitleaks             # or your platform's packages
git clone --branch v4.7.9 --depth 1 https://github.com/samuelgursky/davinci-resolve-mcp.git upstream
luajit test/test_protocol.lua test/fixtures.json
python3 test/e2e_client.py upstream
BRIDGE_CONSOLE_MODE=1 python3 test/e2e_client.py upstream
```

The end-to-end test runs the real MCP client against the bridge serving a fake Resolve. Console
mode strips `io`, `require`, `package` and `debug` from the Lua state, which is exactly what
Resolve's Console gives a script, and starts the bridge through `resolve_bridge.lua` the way a user
does. To try a change inside Resolve itself, set `RESOLVE_BRIDGE_DIR` to your checkout before the
`dofile` line, or run the installer again to copy it into place.

`test/fixtures.json` was produced by the upstream client's own signing code
(`test/make_fixtures.py`), so the Lua side is tested against exactly what the MCP server sends.
Regenerate it only when the upstream protocol changes.

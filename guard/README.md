# The guard

`resolve-mcp-guard.py` is a Claude Code hook. It runs before every call to a `davinci-resolve` MCP
tool and refuses three of them.

| Refused | Why |
|---|---|
| `project_manager` with `apply_spec`, or any input naming `run_hooks` | Spec hooks execute arbitrary commands as your user account, with no confirmation |
| `setup` calls that touch the destructive defaults | They can switch off the server's own confirmation gate and safe mode |
| `media_analysis` with `cleanup_artifacts` | It deletes a caller-chosen directory tree with no confirmation |

These came out of reading davinci-resolve-mcp v4.7.9 before I let it run. Nothing in it is
malicious, but these three calls give a model more reach than I want it to have unprompted, so the
hook refuses them. Everything else passes through untouched; the decision travels in JSON and the
hook always exits 0. On a payload it cannot parse it makes no decision at all, so Claude Code's own
permission prompt applies as if the hook were not there.

## Wiring it into Claude Code

The installer copies the hook next to the bridge. Add this to `~/.claude/settings.json` (create the
`hooks` block if there is none):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__davinci-resolve__.*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.config/davinci-resolve-mcp/console-bridge/guard/resolve-mcp-guard.py",
            "timeout": 10,
            "statusMessage": "Resolve MCP guard"
          }
        ]
      }
    ]
  }
}
```

On Windows, write the path out in full with forward slashes, for example
`python C:/Users/<you>/.config/davinci-resolve-mcp/console-bridge/guard/resolve-mcp-guard.py`.

Restart Claude Code. To prove it is live, ask Claude to run `apply_spec` on a project; the reply
should be the refusal text from the hook, not a Resolve result.

Claude Desktop and Cursor have their own permission systems and do not run Claude Code hooks. The
same three calls are worth refusing there through whatever tool allow list the client offers.

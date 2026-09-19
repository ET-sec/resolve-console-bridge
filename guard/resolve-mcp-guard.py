#!/usr/bin/env python3
"""PreToolUse guard for the davinci-resolve MCP server (v4.7.9 security review, 2026-09-17).

Refuses the calls that hand the model more power than the workflow needs:
  1. project_manager apply_spec, or any project_manager input that mentions run_hooks
     (spec hooks execute arbitrary argv as the user, with no confirm token)
  2. setup calls that touch the destructive defaults (they can switch off the confirm gate)
  3. media_analysis cleanup_artifacts (rmtree of a caller-chosen root, no gate)
Everything else passes through untouched. Exit 0 always; the decision travels in JSON.
"""
import json
import sys

REASONS = {
    "apply_spec": "project_manager apply_spec is blocked: spec hooks can run arbitrary commands. Build the project with create/load/save and the timeline tools instead.",
    "run_hooks": "run_hooks is blocked on this machine: it executes arbitrary argv as the user.",
    "setup_destructive": "setup may not change destructive defaults from a session: require_confirm_token and safe_mode are pinned in logs/media-analysis-preferences.json.",
    "cleanup_artifacts": "media_analysis cleanup_artifacts is blocked: it deletes a caller-chosen directory tree with no confirm gate. Remove analysis artifacts by hand.",
}


def deny(reason_key: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": REASONS[reason_key],
        }
    }))
    sys.exit(0)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    tool = str(payload.get("tool_name", ""))
    if not tool.startswith("mcp__davinci-resolve__"):
        return
    short = tool[len("mcp__davinci-resolve__"):]
    tool_input = payload.get("tool_input") or {}
    action = str(tool_input.get("action", "")).strip().lower()
    blob = json.dumps(tool_input).lower()

    if short == "project_manager":
        if action == "apply_spec":
            deny("apply_spec")
        if "run_hooks" in blob:
            deny("run_hooks")
    elif short == "setup":
        if action in {"set_defaults", "set", "configure", "clear", "reset", "clear_defaults"} and (
            "destructive" in blob or "confirm_token" in blob or "safe_mode" in blob or "audit_log" in blob
        ):
            deny("setup_destructive")
    elif short == "media_analysis":
        if action == "cleanup_artifacts":
            deny("cleanup_artifacts")
    elif "run_hooks" in blob:
        deny("run_hooks")


if __name__ == "__main__":
    main()

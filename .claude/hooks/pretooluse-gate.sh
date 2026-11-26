#!/bin/sh
#
# The pre-flight gate's Claude Code PreToolUse hook (opt-in; not enabled in
# .claude/settings.json, because every session on a shared host reads that
# file). See docs/system-one/pre-flight-gate.md for the settings snippet.
#
# Hands the hook input to ash_agent_tools' adapter, which posts it to the
# ash_agent daemon (`devenv shell -- mix ash_agent.serve --port 4197`, the
# port .mcp.json uses) and prints Claude Code's decision. The rules are
# priv/decisions/agent_gate_rules.dmn, then the package's generic seed.
#
# When the adapter itself is missing (deps not fetched), the call is put to a
# person: a hook that cannot run must not read as an allow.

: "${ASH_AGENT_GATE_URL:=http://127.0.0.1:4197/gate}"
export ASH_AGENT_GATE_URL

adapter="${CLAUDE_PROJECT_DIR:-.}/deps/ash_agent_tools/priv/hooks/claude_pretooluse.sh"

if [ -x "$adapter" ]; then
  exec "$adapter"
fi

cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"The pre-flight gate adapter is missing (run mix deps.get): a person decides."}}'

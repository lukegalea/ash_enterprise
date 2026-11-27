# The pre-flight gate: this repository's rules, before a tool call runs

**Tickets:** AST-77 (the deterministic rung: rules as a DMN table) and
AST-78 (the Claude Code and opencode adapters). **Mechanism:**
`AshAgentTools.Gate`, from the `ash_agent_tools` dev dependency.
**Status:** opt-in. Nothing here runs until a person enables the hook.

---

## What it does

Before an agent's tool call runs, a hook posts it to the `ash_agent`
daemon, which asks two DMN decision tables, in order:

1. `priv/decisions/agent_gate_rules.dmn` — this repository's rules, each
   citing the line of `CLAUDE.md` or the ship-a-change skill it comes
   from;
2. the generic seed that ships with `ash_agent_tools` — force pushes,
   pushes from a community fork, `--no-verify`, killing processes by
   pattern, and a push from a repository it cannot classify.

The first answer that is not `defer` wins. The answers:

| Answer | What the hook does |
|---|---|
| `deny` | The call is refused, with the rule's reason. |
| `ask` | A person decides (Claude Code's permission prompt). |
| `allow` | A rule allows it explicitly, so the seed does not refuse it. The harness's own permissions still apply. |
| `defer` | No rule spoke. The harness's own permissions decide. |

This repository's rules:

| Rule | Answer | Source |
|---|---|---|
| `ae_ci_force_push` | allow `git push -f origin HEAD:refs/heads/ci/<name>`, exactly, with a `-C` directory spelled as a plain path | CLAUDE.md:57-60, ship-a-change:66 |
| `ae_ecto_drop_shared` | deny `mix ecto.drop`/`ecto.reset` without `DB_NAME` | ship-a-change:24, :106 |
| `ae_ecto_drop_own` | ask before dropping a database the command names | ship-a-change:106 |
| `ae_bare_mix` | deny `mix` run as a command outside quotes, which is outside `devenv shell --` | CLAUDE.md:13-14 |
| `ae_phx_server` | ask before `mix phx.server` | CLAUDE.md:27 |
| `ae_vendored_cdm` | deny edits under `priv/cdm/schemaDocuments/` | CLAUDE.md:54-55 |
| `ae_generated_migration` | deny edits to migrations and resource snapshots | CLAUDE.md:52, 43-44 |
| `ae_agents_md` | ask before editing `AGENTS.md` | CLAUDE.md:86-87 |

Force to `main` or any other branch, a compound command that hides a
second push, and a `-C` directory the shell would compute (`$(...)`, a
backtick), fall through to the seed's `gate_force_push` and are denied.

The tables read the command with the shell's other spellings of a plain
command written plainly (`$IFS` as a space, an unquoted newline as `;`,
`"--force"` as `--force`). A file path is relative to its own nearest
repository, so the path rules see a file in a worktree under
`.claude/worktrees/` from a session whose cwd is the main checkout. Shell
and file-writing MCP tools meet the same rules as `Bash` and `Edit`, and
a tool that evaluates code (Tidewave's `project_eval`) is asked about:
no pattern can read it.

Every decision is appended to `.agents/logs/gate.jsonl` (ignored by git)
with the rule, the table's SHA-256 and the rules the engine matched. No
model is called: the evaluation is `ash_decisions`' dry evaluation.

**The gate is a guardrail, not a security boundary.** Its patterns see
only what they anticipate. Sandboxes and the harness's permissions remain
the security controls.

## Enabling it (opt-in)

It is not enabled in the committed `.claude/settings.json`, because every
session on a shared host reads that file. To enable it for yourself:

1. Start the daemon (compile-only; it must not share the `iex-server` VM):

   ```bash
   devenv shell -- mix ash_agent.serve --port 4197
   ```

2. Add the hook to `.claude/settings.local.json` (yours, not committed):

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "\"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/pretooluse-gate.sh\"",
               "timeout": 5
             }
           ]
         }
       ]
     }
   }
   ```

3. For opencode, copy `deps/ash_agent_tools/priv/hooks/opencode-gate.ts`
   into `.opencode/plugins/` and set `ASH_AGENT_GATE_URL=http://127.0.0.1:4197/gate`.

While the daemon is down, every call except a read-only one is put to a
person: an unanswered gate is not an allow. That is the cost of enabling
the hook without the daemon running.

## Changing a rule

Edit `priv/decisions/agent_gate_rules.dmn` (in the XML or the operator
decision editor). Write a new pattern as an input column of type boolean
(`matches(command, "...")`) and the rule as a row of `true`, `false` and
`-`, so the verifier can reason about it; cite the source line in the
rule's description. Then:

```bash
devenv shell -- mix ash_agent.gate --verify
devenv shell -- mix ash_agent.gate --explain '{"tool":"bash","command":"git push -f origin main","cwd":"."}'
devenv shell -- mix test test/ash_enterprise/agent_gate_rules_test.exs
```

The daemon picks up the edited table on its next call.

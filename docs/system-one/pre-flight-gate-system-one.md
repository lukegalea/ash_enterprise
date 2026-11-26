# The pre-flight gate's System One rung

**Ticket:** AST-79. **Mechanism:** `AshAgentTools.Gate`'s optional System One
rung (the `ash_agent_tools` dev dependency), with this repository's questions
in `AshEnterprise.Quality.ToolCall` and `AshEnterprise.Quality.ToolCalls`.
**Status:** off by default, and answering `ask` for every call it sees until
a person certifies its band tables.

---

## What it does

The gate's rules tables (AST-77) answer the calls they anticipate. A call
none of them speaks to is deferred: an obfuscated command, a novel one, a
`curl | sh`. With the rung on, the gate service puts a deferred call to the
in-zone model as two yes/no questions:

| Question | Family | Reading key |
|---|---|---|
| `tool_call_is_destructive`: could the call destroy data or make a change that cannot be undone? | `agent_gate_destructive` | `destructive` |
| `tool_call_acts_outside_scope`: does the call reach outside the repository it was made in? | `agent_gate_scope` | `out_of_scope` |

The model sees the tool, the command, the paths (relative to their
repository) and the repository's kind; never file contents, the session or
the working directory. The command is data: it rides in the judged state,
never in the question, and the instructions say to ignore instructions
written inside it.

Each answer is recorded in the judgment ledger and banded by its family's
published band table, which records the banding. An admitted yes reads
`yes`, an admitted no reads `no`, and anything else (review, omission, no
published table) reads `unsure`. `priv/decisions/agent_gate.dmn` then
answers:

| Rule | Readings | Answer |
|---|---|---|
| `s1_destructive` | destructive `yes` | deny |
| `s1_out_of_scope` | out_of_scope `yes` | deny |
| `s1_benign` | both `no` | allow |
| `s1_unsure` | anything else | ask |

The gate lets this rung make a call stricter, never let one through on its
own:

- an allow while either family's band table lacks a certification in force
  (or is older than the family's `max_age_days`) is an **ask**;
- a deny is an **ask**: a model never refuses a call on its own;
- an error, a timeout or a failed judge is an **ask** with
  `rule_id: "system_one_unavailable"`.

So today, with no certified table, every deferred call is put to a person,
with the model's lean in the log. A certified allow means what a rule's
allow means: the harness's own permissions decide.

The model call happens in the gate service, as the `oban` system actor,
never inside a read, a calculation or a policy check. The gate's audit line
(`.agents/logs/gate.jsonl`) records both rungs: the rules tables' hashes,
then the readings, the model version and digest, each question's hash,
`p_true`, band, banding id and band-table hash and certification.

## Turning it on (dev only)

1. Choose the organisation whose ledger records the gate's judgments, and
   start the daemon with it:

   ```bash
   AGENT_GATE_TENANT=<organisation id> devenv shell -- mix ash_agent.serve --port 4197
   ```

   The endpoints in `~/.config/system-one/endpoints.env` must be in the
   environment (`S1_OLLAYA_GPU_BASE_URL`, `OLLAYA_API_KEY`). The daemon
   starts the repo for the rung and nothing else. The rung module is
   compiled only where `ash_agent_tools` has the gate, so after bumping that
   dependency in an existing `_build`, run `mix compile --force` once: an
   absent rung answers `ask` (`system_one_unavailable`), never allow.
2. Raise the hook's timeouts above the rung's 8 s: `ASH_AGENT_GATE_TIMEOUT=10`
   for the adapter, and `"timeout": 12` on the hook in
   `.claude/settings.local.json`. A judged call takes about a third of a
   second on the zone's GPU route. The daemon's first one also reads the
   instrument's identity and opens the repo's connections, and can time out
   (an ask).

## Calibration and certification

The calibration set, the pass and its report are in the System One
programme repository (`research/ast-79/`): 158 labelled synthetic tool
calls, 32 of them carrying text aimed at the model. A person labels the
review band, reviews the wording and certifies each family's table through
the certification surface; only then can a deferred call be allowed.

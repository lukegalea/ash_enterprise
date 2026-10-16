# Draft: ash_ai issue / forum post: let packages add dev MCP tools

**Channel:** GitHub issue on ash-project/ash_ai, or the Ash forum / Discord. Luke posts it himself.
**Status:** DRAFT. Post this before opening the seam PR (`ash-ai-pr-dev-tool-domains.md`).

---

## Title

Dev MCP server: let other packages contribute tools (`dev_tool_domains:`)

## Body

The README's Dev MCP section says "We are still experimenting to see what tools (if any) are useful while
developing with agents." Here is one data point, and a small change that would let packages run that experiment
without forking ash_ai.

**What we've found useful.** In ash_agent_tools (github.com/lukegalea/ash_agent_tools) we've been giving coding
agents read-only, framework-level answers about an Ash app:

- `ash_describe`: a resource's or action's actual contract (accepts, arguments, required/optional inputs, code
  interfaces, source locations).
- `ash_validate`: cast params through the action's real changeset/query/input and report per-path errors. The
  subject is built but never run.
- `ash_can` / `ash_forbidden`: whether an actor may run an action and which policy decides it, evaluated with
  `run_queries?: false`.
- `ash_context`: what Ash construct sits at a given file and line.

They target a failure we see often: an agent guessing an action's inputs or policy outcome from source instead of
asking the framework.

Here they are on `/ash_ai/mcp` in ash_enterprise, using the branch below:

```text
$ initialize
{"protocolVersion":"2024-11-05","serverInfo":{"name":"MCP Server","version":"0.1.0"}}
$ tools/list
["ash_can","ash_context","ash_describe","ash_forbidden","ash_search","ash_validate","get_usage_rules","list_ash_resources","list_generators"]
$ tools/call ash_validate
{"valid?":false,"errors":[{"path":"password_confirmation","message":"is required"},{"path":null,"message":"Invalid value provided for password: length must be greater than or equal to 8."}]}
$ tools/call ash_can
{"allowed":false,"verdict":"forbidden","deciding_checks":["actor holds a role granting this action at sufficient depth","record is shared with the actor or one of their teams","record belongs to someone the actor is above in the hierarchy","action is self-service and the actor is an active member acting for themselves"]}
$ tools/call list_ash_resources (ash_ai built-in, still served)
115
```

**The gap.** `AshAi.Mcp.Dev` sets `tools: :ash_dev_tools`, and `Server.tools/1` turns that into
`[{AshAi.DevTools.Tools, :*}]` plus a literal list of names. A package can't add a tool to the dev server today; the
workaround is to mount a second `AshAi.Mcp.Router` in dev, so agents end up with two dev servers. (The literal list
also still names `list_packages_with_rules`, which no longer exists.)

**Proposal.** `plug AshAi.Mcp.Dev, otp_app: :my_app, dev_tool_domains: [SomePackage.DevTools]`. Each entry is an
ordinary Ash domain that uses the `AshAi` extension and declares its tools in `tools do`, the same way
`AshAi.DevTools` does. The server unions those domains' resources into `:actions` and reads the allowed tool names
from their `tools` entries instead of the literal list. With no option, behaviour is unchanged. I have a branch with
tests and would be glad to open it as a PR if the shape looks right. Name suggestions welcome (`extra_dev_tools`?).

One question we noticed while reading the code: `resources/list` on the dev server goes through
`mcp_action_resources/1`, which doesn't apply the dev scoping, so the dev server advertises the app's own
`mcp_resources`. Is that intended?

— Luke

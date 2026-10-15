Status: draft — Luke opens this PR himself from lukegalea/ash_ai:feat/dev-tool-domains

---

## Title

improvement: let `AshAi.Mcp.Dev` serve tools from other AshAi domains (`dev_tool_domains:`)

## Body

The README's Dev MCP section says "We are still experimenting to see what tools (if any) are useful while developing
with agents." Today that experiment can only happen inside ash_ai: `AshAi.Mcp.Dev` always sets
`tools: :ash_dev_tools`, and `Server.tools/1` turns that into `[{AshAi.DevTools.Tools, :*}]` plus a literal list of
tool names. A package that wants to offer a dev tool has to mount a second `AshAi.Mcp.Router`, so agents end up
talking to two dev servers.

This PR adds one option so a package can contribute dev tools as an ordinary AshAi domain:

```elixir
if code_reloading? do
  plug AshAi.Mcp.Dev,
    otp_app: :my_app,
    dev_tool_domains: [SomePackage.DevTools]
end
```

Each entry is an Ash domain that uses the `AshAi` extension and declares its tools in `tools do`, the same way
`AshAi.DevTools` does.

### What changes

- `AshAi.Mcp.Dev.init/1` accepts `:dev_tool_domains` (default `[]`) and validates it. It raises `ArgumentError` if
  the value isn't a list, an entry isn't a loaded module, isn't an Ash domain, or doesn't use the `AshAi` extension,
  or if a contributed tool name collides with another dev tool.
- In `AshAi.Mcp.Server.tools/1`, the `:ash_dev_tools` branch now builds `:actions` and the tool allowlist from the
  `tools` entries of `AshAi.DevTools` and each `dev_tool_domains` domain (domain-level and resource-level, via
  `AshAi.Info.tools/1`), instead of a literal list.
- `:dev_tool_domains` is threaded through `tool_definitions/1` and `find_tool_by_name/3` so `tools/list` and
  `tools/call` both see it.
- README and usage-rules.md get one example each. The "still experimenting" sentence stays.

### Backwards compatibility

- With no `dev_tool_domains`, the dev server serves the same three tools as before: `list_ash_resources`,
  `get_usage_rules`, `list_generators`. There is a test for this.
- The production path (`AshAi.Mcp.Router` with `tools:` / `otp_app:`) is untouched; the option only takes effect when
  `tools` is `:ash_dev_tools`, which only `AshAi.Mcp.Dev` sets.
- The literal list also named `:list_packages_with_rules`, which no longer exists in `AshAi.DevTools`. Reading the
  names from the domain drops it. It was never served, since nothing provided a tool by that name.

### A question, not changed here

`resources/list`, and the `resources` capability in the `initialize` result, go through `mcp_action_resources/1` and
`mcp_ui_resources/1`. Those don't apply the dev scoping: on the dev server `:actions` is unset, so they resolve the
app's `ash_domains` from `otp_app`, and the dev server advertises the app's own `mcp_resources`. Is that intended? If
not, the same `dev_tools` list could scope them; happy to do that here or separately.

### Naming

`dev_tool_domains` is a suggestion. `extra_dev_tools` would also work if you prefer a name that doesn't mention
domains.

### Worked example

ash_agent_tools (github.com/lukegalea/ash_agent_tools) has an optional adapter, `AshAgentTools.AshAi`, which is an
AshAi domain wrapping its read-only Ash introspection tools. With this branch it is mounted with
`dev_tool_domains: [AshAgentTools.AshAi]`.

Live run on 2026-10-15 in ash_enterprise (27 domains), with ash_ai on this branch and
`plug AshAi.Mcp.Dev, otp_app: :ash_enterprise, path: "/ash_ai/mcp", dev_tool_domains: [AshAgentTools.AshAi]`.
Requests are JSON-RPC POSTs to `/ash_ai/mcp`; tool output is trimmed with `jq`.

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

### Verification

`mix compile --warnings-as-errors`, `mix test`, `mix format --check-formatted`, `mix spark.formatter --check`,
`mix credo --strict`, `mix sobelow --skip`, `mix dialyzer`, `mix docs` and `reuse lint` pass locally. On a heavily loaded machine `ToolLoopStreamingTest` occasionally timed out (1000ms `assert_receive`); it passes on rerun and is untouched here. New tests are in
`test/ash_ai/mcp/dev_test.exs` and drive the `AshAi.Mcp.Dev` plug directly.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Status: opened 2026-10-21 as https://github.com/ash-project/ash_ai/pull/255. This is the as-drafted text; the posted body has post-rebase verification.

---

## Title

fix: MCP server name uses the otp_app, and the installer's fallback warning shows the plug

## Body

Two small fixes found while reading the dev MCP code.

**`AshAi.Mcp.Server.get_server_name/1` had its condition inverted.** With `otp_app` set it returned
`"MCP Server"`; without it, it returned `" MCP Server"` (an empty interpolation). It now returns:

- `mcp_name` when given (unchanged),
- `"<otp_app> MCP Server"` when `otp_app` is set,
- `"MCP Server"` otherwise.

This changes the `serverInfo.name` a client sees for any server configured with `otp_app` and no `mcp_name`, for
example `"my_app MCP Server"` instead of `"MCP Server"`. Two existing assertions that pinned the old value are
updated, and there are unit tests for the three cases.

**The `ash_ai.gen.mcp` fallback warning was truncated.** When the installer can't find `if code_reloading? do` in the
endpoint, the warning ended with `if code_relading?` (typo, no snippet). It now shows the full block:

```elixir
if code_reloading? do
  plug AshAi.Mcp.Dev,
    otp_app: :my_app,
    path: "/ash_ai/mcp"

  # ...
end
```

There is a test that removes the `code_reloading?` block from a generated Phoenix project and checks the warning.

### Verification

`mix compile --warnings-as-errors`, `mix test`, `mix format --check-formatted`, `mix spark.formatter --check`,
`mix credo --strict`, `mix sobelow --skip`, `mix dialyzer`, `mix docs` and `reuse lint` pass locally. On a heavily loaded machine `ToolLoopStreamingTest` occasionally timed out (1000ms `assert_receive`); it passes on rerun and is untouched here.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

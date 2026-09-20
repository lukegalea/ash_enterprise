# Codicil (E-xyza/codicil) — Assessment

*Assessed 2026-09-20 via DeepWiki (repo + docs). MIT, v0.7.0 (2025-11-22), dev-only dep.*

## What it is
Compiler-tracer-based code indexer for Elixir with an MCP read path: `Codicil.Tracer` hooks `elixirc_options: [tracers: [...]]`; per-module GenServers extract BEAM metadata into SQLite (Ecto) with `sqlite-vec`; an LLM+embeddings enrichment pass writes natural-language summaries and vectors per function; a FileWatcher recompiles on change. MCP served over HTTP (`/codicil/mcp` via Phoenix Plug or standalone Bandit). Tools: `find_similar_functions` (NL vector search), `list_function_callers/callees`, `list_module_dependencies/dependents`, `get_function_source_code`.

## Verdict for our program: don't adopt as a dependency — steal three ideas

**Why not adopt:** (1) function/module granularity only — Spark DSL entities are opaque to it, same blind spot as Serena/Expert, so it doesn't touch our core lane; (2) its summaries/embeddings are LLM-derived — approximate, drift-prone, provider-key-dependent — the opposite of our exact-manifest determinism story (our validate-by-casting vs its summarize-by-LLM); (3) activity looks slow (last release ~10 months old); (4) overlap: callers/callees ≈ Serena find_referencing_symbols ≈ our context/3 references.

**What to steal:**
1. **Compile-tracer call graph.** `list_function_callers/callees` from tracer events is exact and cheap — feeds SEM-1's `safe_delete_entity` impact analysis (who calls the code-interface function wrapping the entity we want to delete) better than LSP references in some cases. A tracer appendix to ash_agent_tools (opt-in dev tracer persisting a call-graph edge table) is small and deterministic — no LLM anywhere.
2. **NL semantic search as an optional future module.** Their `find_similar_functions` is genuinely useful and we deliberately have no embeddings story. If we ever add one, enrich OUR manifest symbols (typed entities with real contracts) instead of raw functions — higher-quality summaries, less drift, and the tracer keeps embeddings fresh on recompile.
3. **Transport + tooling patterns for DX-2.** MCP-over-Plug inside the dev Phoenix endpoint (or standalone Bandit via a mix alias) is exactly the serving shape our `ash_agent.serve` daemon needs; their MCP tool-description overriding is a nice touch for per-agent tool contracts.

**Capstone note:** optional third MCP server in the demo (NL search is a flashy demo beat), but it requires provider keys and adds a non-deterministic tool — keep behind an optional section in CAP-3, not the default setup.

## Ecosystem scan addendum: agentjido/awesome-elixir-ai (2026-09-20)
Early-stage curated list (29★, "Elixir AI Swarm Collective", CC0, PRs welcome, alphabetical, `[Name](link) - Description.` format). Notable finds for us:
- **Cohere (mhyrr/cohere)** — "generates a system map for Elixir/Phoenix projects and checks project intent for drift" — closest prior art to our semantic-map/Clarity lane; needs a look before we claim novelty on drift-checking.
- **Anubis MCP (zoedsoupe/anubis-mcp)** — Elixir MCP SDK, STDIO/HTTP/SSE/WebSocket transports — candidate substrate for DX-2's `ash_agent.serve` instead of hand-rolled Plug routing (vs Codicil's Plug pattern; pick one).
- **ash-project/evals** — Zach's tool for evaluating models on Elixir codegen — the harness Lane C should use to benchmark Expert completion quality.
- **Gaps in their list = our openings**: no Serena, no Expert, no Codicil, no observer_cli, no semantic-introspection entries at all. Once ash_agent_tools is public, an entry PR is natural distribution; the capstone demo fits "Starters, Templates & Examples". Both Luke-gated per protocol.

**Community note:** E-xyza org = the Zorn/oracle ecosystem people; a potential friendly venue for our MCP/agent tooling conversations. AgentJido collective (Discord, monthly ElixirForum showcases) is the second venue — capstone demo is a natural monthly-showcase post.

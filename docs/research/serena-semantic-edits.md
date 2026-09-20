# Serena (oraios/serena) — Semantic-Edit Toolkit Research & Integration Plan

*Researched 2026-09-20 (lib-5) via live fetch of README/docs/source (symbol_tools.py, lsp_api.py, code_editor.py, ls_config.py, cli.py, mcp.py, CHANGELOG) + issue tracker. Tags: [verified] fetched today · [verified-negative] confirmed absent · [inferred] analysis.*

## Vitals [verified]
29.6k★, very active (PR #1980 merged Sep 3 2026). Tagline "The IDE for Your Coding Agent". **License: SolidLSP (src/solidlsp) = MIT; everything else GPL-3.0+; CLA required** — we may copy *design* freely; GPL code linkage matters. Elixir tagline: SolidLSP supports 40+ languages.

## 1. Architecture
- **SolidLSP** (fork-lineage of microsoft/multilspy, now synchronous) wraps LSPs; second backend = paid JetBrains plugin; both behind `CodeEditor`/`Symbol` interfaces (proof the backend seam is real).
- **MCP topology**: `serena start-mcp-server` — stdio/sse/streamable-http (HTTP mode shares one instance across agents); **Web Dashboard port 24282** (logs, tool-usage stats, memories GUI).
- **Serena v2 dual interface**: classic per-op Tools + BETA single-tool **REPL** over facades (lsp/fs/edit/mem…) with progressive disclosure — their answer to N-tools context tax.
- **Contexts** (claude-code/codex/ide/agent…) disable tools overlapping the harness; **modes** (planning/editing/onboarding…); config layering global→CLI→`.serena/project.yml`; `excluded_tools`; per-language LS pins via `ls_specific_settings.<lang>` incl. `ls_path`/`ls_args`.
- **Memories**: plain Markdown `.serena/memories/` (+ global), `mem:name` cross-refs with rename rewriting, referential-integrity CLI; onboarding seeds a maintenance memory on first activation. Explicitly rejects DB/vector/trigger-injected memory. ("Project Briefs" — no such feature exists [verified-negative]; "YAGNI memo" = folklore [verified-negative]; the real signals are the v2 *deletion* of six think_* meta-tools and brutally honest self-evals.)

## 2. Toolset (semantics)
Symbol tools address by **name_path** (`Class/method`, leading `/` absolute, `[i]` overloads; Erlang `name#arity`); project-relative paths only; every tool takes `max_answer_chars` with graceful **truncation ladders** (full → refs-without-context → per-file counts → "Found N references.").
- `find_symbol(name_path_pattern, depth, relative_path, include_body/info/kinds, substring_matching, max_matches)` — over-limit **raises with shortened file→name_paths map** to force refinement.
- `get_symbols_overview` — "first tool for a new file", structure-only.
- `find_referencing_symbols` — refs as symbols + content_around_reference.
- `replace_symbol_body` / `insert_after_symbol` / `insert_before_symbol` — anchor edits with blank-line normalization; docstring-level (NOT mechanical) read-before-edit [verified-negative: no hard gate].
- `rename_symbol` — LSP rename → WorkspaceEdit applied across files.
- `safe_delete_symbol` — refuses with the reference list unless zero refs (no unconditional delete exists [verified-negative]).
- `get_diagnostics_for_file/_symbol`, `restart_language_server` (external-edit desync recovery). No standalone `get_body_location` tool [verified-negative].

## 3. Edit-safety model [verified from code]
replace_symbol_body = unique-symbol resolve (ambiguity = error) → whole-definition range (per-LS normalization; gopls keyword-range bug history) → strip + splice against the LS-open buffer (didOpen/didChange full-sync) → **atomic write** with configured encoding/EOL → **post-edit LS diagnostics appended to the result**. Rename = TextEdits + file renames. No idempotency/verify-revert [verified-negative]. Failure history: range-fidelity bugs, name-addressing collisions (Erlang #1797), stale-LS desync, token cost of body-level edits for small changes (their own evals concede built-ins win there).

## 4. Elixir status [verified]
**Elixir backend = Expert** ("official Elixir language server"), pinned `v0.1.0-rc.6`, auto-downloaded binaries, `expert --stdio`; requires compiled project; cross-file wait 10s; ignores _build/deps/.elixir_ls. **Their test suite xfails an Expert bug: `XPExpert.EngineApi.document_symbols/2` FunctionClauseError (nil document_symbols for some files)** — directly actionable in our fork. Issue history: #1397 didOpen/300s timeout (closed), #1444 monorepo mix.exs deadlock fix (merged), #1563 Dexter alt-backend (abandoned). Stale "Next LS" fossil in the Elixir README. **You can point Serena at our forked Expert binary today via `ls_specific_settings.elixir.ls_path`.** Language-agnostic parts (memories, onboarding, dashboard) usable standalone. **Limit: Expert/LSP granularity is module/function — Spark DSL blocks are opaque text to Serena.**

## 5. Adoption mapping → ash_agent_tools
| Serena | Us |
|---|---|
| name_path addressing | DSL-entity name paths over manifest: `MyApp.Accounts.User/actions/read`, `.../policies/policy[0]`; formalize grammar in context/3 |
| get_symbols_overview + truncation ladders | describe already covers; adopt ladders + "first tool" prompt contract |
| find_referencing_symbols | complete context/3 refs by joining manifest cross-refs (code interfaces, manage_relationship targets, policy subjects) + snippets |
| replace_symbol_body | `replace_entity_block`: span from __spark_metadata__/section_anno → splice → atomic write → **`mix ash_agent.validate` + compile as our diagnostics_context (semantic, not just diagnostic)** |
| safe_delete_symbol | `safe_delete_entity`: refuse with manifest/LiveView reference list; pair with diff |
| rename_symbol | **not portable via LSP** — action names are data; manifest-driven rewrite only. Genuine differentiator |
| read-before-edit (prompt-level) | we can do it **mechanically** via manifest shape_hash digest staleness check |
| memories/onboarding/tool minimalism/REPL | per-project `.ash_agent/` notes; keep toolset small; REPL only if count grows |
| contexts disabling overlapping tools | our MCP surface = pure semantic tools only; no file/shell dupes |

**Novel-for-DSLs (Serena structurally can't):** symbol = typed DSL entity (schema-aware insert/validate-before-accept); option-level granularity below entity body; provenance-aware edit redirect/refusal for transformer-injected declarations; validation-by-casting edit gate (incl. accepted-vs-normalized typing honesty); manifest re-emit + shape_hash diff post-edit for idempotency; completion↔edit closed loop via shared manifest with our Expert fork.

**Integration shape [inferred]: two MCP servers side by side** — Serena (generic symbol ops, driven by our forked Expert via ls_path) + ash_agent (DSL semantics). Complementary, not competitive.

## 6. Sequencing (adopted into plan)
1. Harden context/3 into name_path-addressable lookups + laddered outputs.
2. `replace_entity_block` / `insert_before_entity` / `safe_delete_entity` with digest staleness + validate-after-edit.
3. MCP exposure mirroring Serena naming so agents transfer skills.
4. **Fix Expert document_symbols/2 nil bug in our fork → upstream draft PR** (benefits every Serena Elixir user; establishes us as Elixir-semantics upstream).
5. Capstone (CAP-3): Serena + ash_agent dual-MCP wiring per above; GPL boundary respected (no code linkage, config only).

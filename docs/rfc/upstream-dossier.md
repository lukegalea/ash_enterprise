# Community PR Dossier — Ash Semantic Tooling (FIRST-2)

Verified against live GitHub (authed as lukegalea), 2026-09-20. Full research by librarian agent.

## Quick-reference matrix

| Repo | Target issue/PR | Request review from | License | PR-title rule | Pre-code venue |
|---|---|---|---|---|---|
| expert | #826 "Add Ash support", #475 "Autocompletions for Ash", #234 elixir_sense future | mhanberg, doorgan (+zachdaniel Ash-side) | Apache-2.0 | Conventional Commits (commitlint enforced) | Issue + Elixir Forum thread (expert-lsp compatibility) |
| ash | #1971 get_by type-checking ⚠️ torazar active | zachdaniel (barnabasJ context) | MIT (REUSE/SPDX headers on new files) | Conventional Commits | Comment/claim issue first + Discord/Forum |
| spark | new issue (RFC venue — no Discussions); prior art #290, #54 | zachdaniel | MIT (REUSE) | Conventional Commits | Issue + Forum/Discord |
| clarity | #137 ontology report (opened by jimsynz himself, 5 open questions, zero comments) | jimsynz | Apache-2.0 | — | Answer #137 questions in-thread, then PR |
| tidewave | PR #215 (tool-definition API, josevalim, OPEN) | josevalim | Apache-2.0 | conventional | ⚠️ José REJECTED tool-registration PRs (#237, #242); engage #215 first; accepted pattern = usage-rules + project_eval |
| usage_rules | new issue (additive) | zachdaniel | MIT (REUSE) | Conventional Commits | Issue |

## Key facts
- No CLAs anywhere. Default branch `main` everywhere. No Discussions except ash-project/ash.
- ash-project repos use REUSE/SPDX (LICENSES/MIT.txt + per-file headers) — new files need SPDX headers.
- Expert CI: formatter + credo + dialyzer per-app matrix; release-please changelog (never hand-edit).
- Ash CI gate: `mix check` (incl. spark.formatter, sobelow); features must be discussed first (use-case centered); branch convention `feature/<name>`.
- Ash #1971: zachdaniel's desired fix stated in-thread — Ash.Resource.Info.get_field/2 → field.type + constraints → Ash.Type.cast_input/3. ⚠️ torazar "looking into this" — claim before PR.
- Spark RFC framing: reference Expert #826/#475 as consuming use cases; zachdaniel already signaled "something far far better than ElixirSense is possible".
- Clarity #137: mirror lib/clarity/report/security_posture.ex pattern; extend Content Providers (Clarity.Content behaviour) or Report module; `mix ex_check --no-retry` CI; Styler formatting.
- Tidewave strategy: DO NOT pitch tool_providers config. Build on #215's tool-definition exploration; minimize context cost; package contribution as code + usage-rules (accepted pattern per #77/#242).
- Tidewave José rationale: "MCP tools are expensive context-wise… define as Mix tasks with skill/Agents.md… ship regular code and ask agent to use project_eval."

## Coordination warnings
1. Ash #1971: claim the issue (comment) before opening PR; ping torazar/zachdaniel.
2. Tidewave: engage PR #215 discussion before any code.

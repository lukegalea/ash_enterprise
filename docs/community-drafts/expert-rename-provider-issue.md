# Upstream issue draft: Expert lacks textDocument/rename (blocks Serena rename_symbol for Elixir)

**Target:** expert-lsp/expert
**Status:** ready to file; Luke-gated, do not post without approval
**Evidence:** captured in the capstone dogfood —
`textDocument/rename` answered with `-32601 Method not found`; the
`initialize` capability dump declares no `renameProvider` (transcripts on
request; verified against Expert release 0.1.0 built from
`fix/document-symbol-crashes` @537338b, and per Serena's own Elixir wiring).

---

## Title

`textDocument/rename` answered with `-32601`; no `renameProvider` capability — Serena's `rename_symbol` cannot work for Elixir

## Body

### What we're seeing

Expert does not implement `textDocument/rename`:

- the `initialize` result declares no `renameProvider` capability, and
- a `textDocument/rename` request is answered with
  `-32601 "Method not found"` (server stays up; it's a clean method-missing,
  not a crash).

### Why it matters downstream

Serena uses Expert as its Elixir language backend (upstream pins Expert
`v0.1.0-rc.6`). Serena exposes `rename_symbol` as one of its core editing
tools over LSP backends — for Elixir projects this tool can never succeed,
because the backend answers every rename with `-32601`. From the agent's
point of view this is a silent capability hole: `find_symbol` and
`get_symbols_overview` work, so the absence of rename reads as a bug in the
agent rather than a missing server capability.

We hit this while wiring a two-server agent setup (Serena for generic symbol
ops, Ash-based introspection for DSL semantics) and had to drop the rename
demo from our evidence set; the gap log entry is
`rename_symbol unusable against any Expert build`.

### Ask

Either:

1. implement `textDocument/rename` (even a conservative first cut —
   module-local renames with workspace-edit preparation, cross-file
   references already being indexed), or
2. if it's out of scope for now, document the limitation prominently so
   downstream consumers (Serena above all) can degrade gracefully instead of
   exposing a tool that can only fail.

Happy to share our captured transcripts (`initialize` capabilities +
`-32601` exchange) if useful.

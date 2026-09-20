# Upstream PR draft: fix document_symbols crash for unresolvable documents

**Branch:** `fix/document-symbol-crashes` (based on `130058c`, the same base as our
`ash-dsl-candidates` work — this PR is otherwise clean)
**Commit:** `537338b1`
**Status:** ready to paste; Luke-gated, do not push/open without approval

---

## Title

`fix(expert): return empty symbols instead of crashing when the document is unresolvable`

## Problem

`Expert.EngineApi.document_symbols/2` pattern-matches its document argument as
`%Document{}`:

```elixir
def document_symbols(%Project{} = project, %Document{} = document) do
  call(project, Engine, :document_symbols, [document])
end
```

A `textDocument/documentSymbol` request only carries a URI. The handler resolves
the document via `Document.Container.context_document(params, nil)`, and the
`Any` implementation of that protocol falls back to the parent context — `nil` —
whenever the URI is not present in `Document.Store`:

```elixir
def context_document(%{text_document: %{uri: uri}}, parent_context_document) do
  case Document.Store.fetch(uri) do
    {:ok, document} -> document
    _ -> parent_context_document   # nil when the file was never opened / was evicted
  end
end
```

So requesting symbols for a file that is not in the open-document store passes
`nil` straight into `document_symbols/2` and the request dies with
`FunctionClauseError: no function clause matching in Expert.EngineApi.document_symbols/2`.

**"Some files" means exactly this:** any file the client asks about without having
`didOpen`-ed it first (or whose store entry was evicted, e.g. after the temporary-open
timeout). Clients that build symbol indexes by walking files — rather than only
querying open buffers — hit this constantly. Serena's Elixir support (whose backend
is Expert, pinned `v0.1.0-rc.6`) carries an xfail documenting precisely this bug:
`document_symbols/2` raises `FunctionClauseError`, surfacing there as a `nil`
`document_symbols` result for some files.

## Repro

Minimal, against `v0.1.0-rc.6` (and identically against the commit this branch
forks from):

```elixir
# The handler resolves the request document with a nil fallback:
document = Document.Container.context_document(request.params, nil)
# => nil for any URI not in Document.Store

Expert.EngineApi.document_symbols(project, nil)
#=> ** (FunctionClauseError) no function clause matching in Expert.EngineApi.document_symbols/2
```

The regression test added in this PR fails on the base commit with exactly:

```
** (FunctionClauseError) no function clause matching in Expert.EngineApi.document_symbols/2
    Attempted function clauses (showing 1 out of 1):
        def document_symbols(%Forge.Project{} = project, %Forge.Document{} = document)
```

## Fix

Widen the API with a clause for the unresolvable case, so every call returns a
valid (possibly empty) symbol list:

```elixir
def document_symbols(%Project{} = _project, nil), do: []
```

`nil` is the observed offending input (it is the container protocol's documented
fallback); other non-`%Document{}` arguments remain pattern-match errors so real
contract violations are not silently swallowed.

## Test evidence

- `apps/expert/test/expert/engine_api_document_symbols_test.exs` — the xfail-buster:
  asserts `EngineApi.document_symbols(project, nil) == []` instead of raising.
  Verified red (FunctionClauseError) on the base commit, green with the fix.
- `apps/engine/test/engine/code_intelligence/symbols_test.exs` — content-shape
  regression tests documenting that every file shape yields a list, never an
  error: empty file, whitespace-only, comment-only, attribute-only (moduledoc),
  script-style code without any module, sigil-only, unicode-only content.
  All shapes were first sweep-verified against the engine (each previously
  crashed only in environments where support processes were not booted; with the
  document store/application cache running they return `[]`, and these tests pin
  that contract).

Suite results on this branch (OTP 28 / Elixir 1.19.5, the repo's justfile
erl-flags invocation `elixir --erl "-start_epmd false -epmd_module
Elixir.Forge.EPMD" -S mix test`):

| app    | result                                  |
|--------|------------------------------------------|
| engine | 1178 tests, 0 failures (1171 base + 7 new) |
| expert | 852 tests, 2 failures: the long-standing flaky `definition_test` ("find the definition when calling a Elixir std module function") and one engine-node-spawning load flake (`ModulesTest` custom `time_zone_database`) that passes in isolation and is unrelated to this change |

## Notes for reviewers

- The `main` branch's `Expert.Document.Lookup` already avoids the nil path for
  the built-in handler by opening missing files as temporary documents
  (`Document.Store.open_temporary/1`) and answering unresolvable requests with
  `invalid_request`. The widened clause is defense-in-depth at the API boundary
  and fixes the contract for every other/current caller — including pinned
  consumers like Serena and any handler that still uses the container protocol's
  nil fallback.
- Backport note for rc.6 users: the one-line clause applies cleanly to the
  rc.6-era `engine_api.ex`; combined with the handler, requests for unopened
  files then return `[]` instead of erroring.
- Trivial drive-by: removes the stale `!next-ls` entry from the Zed section of
  `pages/installation.md` (Next LS is archived and no longer selectable there).

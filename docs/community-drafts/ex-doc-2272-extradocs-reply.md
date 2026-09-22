# POSTED 2026-09-22 (comment id 5770522538) + issue CLOSED (completed)
# Final body led with "Closing this — prototyped your suggestion today and
# it works great, so no ex_doc change needed. Thank you!" per Luke.

# DRAFT — for Luke's review before posting to elixir-lang/ex_doc#2272

**Post as:** comment on issue #2272 (reply to josevalim)
**Tone rules:** concise, José-style; lead with "it works", show the snippet and
the evidence; state the caveats as observations, not asks; let him decide
whether the issue should close.
**Verified:** 2026-09-22, ex_doc 0.40.3, in the usage_rules checkout
(clean tree, reverted after — nothing committed).

---

Prototyped this today and it works end to end — thank you, this is much
simpler than a new option. For anyone finding this later, the encapsulated
version we landed on:

```elixir
defp docs do
  [
    # ...
    extras:
      [
        {"README.md", title: "Home"},
        "CHANGELOG.md"
      ] ++ extra_docs()
  ]
end

# EXTRA_DOCS=1 mix docs routes standalone agent docs (AGENTS.md-style
# files) through the same extras pipeline, so broken refs warn like any
# other doc. In CI we run it with warnings_as_errors: true.
defp extra_docs do
  if glob = System.get_env("EXTRA_DOCS"), do: Path.wildcard(glob), else: []
end
```

With a file containing planted breakages, `EXTRA_DOCS=1 mix docs` reports:

```
warning: documentation references module "UsageRules.NoSuchModule" but it is undefined
└─ EXTRA_DOCS_PROTOTYPE.md: (file)
warning: documentation references function "UsageRules.Validator.validate/9" but it is undefined or private
└─ EXTRA_DOCS_PROTOTYPE.md: (file)
warning: documentation references "mix no_such.task" but it is undefined
└─ EXTRA_DOCS_PROTOTYPE.md: (file)
```

and with `warnings_as_errors: true` exits 1 (`generation for html, epub
formats failed due to warnings while using the --warnings-as-errors
option`). Without `EXTRA_DOCS` set, `mix docs` is unchanged.

Two observations from the run, both consistent with how moduledocs behave,
so we'd treat them as fine rather than blockers:

- bare undefined module mentions in plain code spans (`` `NoSuch.Module.Here` ``)
  stay silent — only explicit `` [x](`Mod`) ``-style links warn, as in moduledocs
- extras warnings carry the file but no line number

This covers our CI use case (rotting refs in agent-facing markdown break
the build), so from our side the issue can close unless you'd still like
the stricter validation mode as a future direction. Thanks again!

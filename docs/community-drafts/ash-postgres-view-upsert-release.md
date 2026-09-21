# Upstream issue draft: ash_postgres view-upsert regression window (release request)

**Target:** ash-project/ash_postgres
**Status:** ready to file; Luke-gated, do not post without approval
**Framing:** not a bug report for unfixed code — the fix is on main (97ffea95).
The ask is a patch release carrying it, because the regression window coincides
with the security-advisory fix that forces consumers onto 2.13.x.

---

## Title

`2.13.x`: upserts through auto-updatable views regress (`RETURNING xmax` on views) — please ship a release carrying `view? true` (97ffea95)

## Body

### What we're seeing

Since the 2.13 upsert rework, Ash-level upserts against resources mapped to
auto-updatable **views** fail: the emitted statement returns
`RETURNING (alias.xmax = 0)` unconditionally, and views have no system
columns, so Postgres rejects it (column `alias.xmax` does not exist).

`97ffea95` on `main` ("fix: add `view? true` option to support not returning
`xmax`") fixes exactly this, but v2.13.1 is currently 12 commits behind `main`
and does not include it.

### Why the window is awkward

The 2.13 line is also where the recent security advisory fix landed, so
consumers clearing `mix hex.audit` are effectively pushed **onto** 2.13.x —
the only line with the regression — and pinning back to 2.11/2.12 isn't a
reasonable workaround.

Concrete consumer: strangler-fig migrations that map an Ash resource onto a
legacy schema through an auto-updatable view (our `ash_strangler` use case),
where the identity upserts are exactly the operations that now fail. The same
shape hits anyone upserting through views with `ash_authentication`
OAuth2/OIDC identity resources.

### Ask

A patch release (2.13.2) carrying `97ffea95`, so view-backed resources can set
`view? true` and upsert again while staying on the advisory-fixed line. A
backport note for the docs (`view? true` required for view-backed resources on
2.13+) would help discovery.

### Repro sketch

```elixir
# resource backed by an auto-updatable view (strangler pattern):
postgres do
  table "legacy_users_view"
  repo MyApp.Repo
end

# any upsert path (identity upsert, upsert?: true create) emits:
# ... ON CONFLICT ... DO UPDATE ... RETURNING (u0.xmax = 0) AS ...
# => ERROR: column u0.xmax does not exist  (views have no system columns)
```

Workaround until a release ships: none that we found short of mapping the
resource onto the base table or skipping the upsert path.

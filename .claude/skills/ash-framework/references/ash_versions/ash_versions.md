# Rules for working with AshVersions

## Understanding AshVersions

AshVersions has two parts. `AshVersions.Registry` is a version registry: a host declares each
versioned resource once as an `AshVersions.Artifact`, and gets discovery, a header, a semantic
diff and validation. `AshVersions.TemporalHistory` recovers every version of a temporal record
through as-of reads. Read the module docs before declaring anything.

## Declaring a registry

- One host module `use`s `AshVersions.Registry` and implements `artifacts/0`, `tenant/1`,
  `open?/2`, `publisher/3` and `translate/1`. Call the registry through that module
  (`MyApp.Versions.diff/4`), not through `AshVersions.Registry` directly.
- Every entry names its `door`. There is no default. Use the door of the page that already lists
  those rows, so a type is never visible here and hidden there.
- `scope: :tenant` reads in the viewer's tenant and leaves the rest to the resource's policies.
  Use `scope: {:attribute, :organization_id}` for rows that carry the tenant in a column, where
  `nil` means the row holds for every tenant.
- Name only attributes that exist on the resource (`identity`, `version`, `lineage`,
  `content_hash`, `parent`, the lifecycle attribute). Test that in the host. The package does not
  check it at compile time.
- Class every lifecycle state the resource allows. A state the map leaves out is `:unknown`,
  never `:current`.
- `publisher/3` returns `:unreadable` when the viewer may not read the record of who published.
  It must never return `:not_recorded` for a viewer who simply cannot see it.

## Differs

- A differ implements `AshVersions.Differ`: `aspects/0` labels what it compares in the host's
  words, and `diff/3` compares by meaning, never by text.
- When a package owns the format, call its comparison and wrap the result in
  `AshVersions.Change`s (`Change.keyed/3`, `Change.value/4`). Do not re-implement it.
- Return `{:ok, []}` only after comparing both versions. Return `{:error, reason}` when you could
  not compare.

## Reading the results

- Only `{:unchanged, _}` from `diff/4` means "no changes". `:uncovered`, `:no_differ`, `:first`,
  `:unchained`, `{:unreadable, :from}` and `{:failed, _}` each need their own words on the page.
- Only `{:ok, []}` from `validation/2` means valid. `:undeclared` and `{:failed, _}` are "not
  checked".
- `get/3` and `used_by/4` return `:unreadable` for anything the viewer cannot read, a malformed
  id included. Never show that as "not found".

## Temporal history

- `TemporalHistory.versions(resource, seeds, actor: actor, tenant: tenant)` walks from the
  versions you already read. Seed it with every instant the page shows, or a gap hides history
  on the far side.
- It costs one read per version and is capped by `:max_versions` (default 50) per record and
  direction. Use it for the records one page shows, never for a table.
- Every step is a read as the caller, so a version the caller may not read ends the walk. Do not
  pass `authorize?: false` to get around a policy.
- Use `starts_at/1` and `ends_at/1` rather than reading the period attribute. `ends_at/1` is
  `nil` for the open version.

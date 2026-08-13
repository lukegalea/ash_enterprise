# Postgrex type extensions for this repo.
#
# This file intentionally contains no module definition -- `Postgrex.Types.define/3`
# defines the module itself, and it must be called at the top level. Wrapping it
# in a `defmodule` will not work.
#
# `AshPostgres.Extensions.Vector` teaches Postgrex how to encode and decode the
# pgvector `vector` type on the wire. It is a *type* extension and is unrelated to
# the `installed_extensions/0` list in AshEnterprise.Repo, which controls
# `CREATE EXTENSION` in migrations. Both are required for pgvector: one so the
# extension exists in the database, this one so the driver can talk about it.
#
# Referenced from `config :ash_enterprise, AshEnterprise.Repo, types: AshEnterprise.PostgrexTypes`.
Postgrex.Types.define(
  AshEnterprise.PostgrexTypes,
  [AshPostgres.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)

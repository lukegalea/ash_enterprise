defmodule AshEnterprise.Planning.Binding do
  @moduledoc """
  A tenant's binding of `(model_key, purpose)` to the definitions a plan is made with (ADR
  0062): `AshPlanning.Fragment.Binding` on the platform base, in table
  `planning_bindings`.

  Temporal (ADR 0049): re-binding closes the version valid until `as_of` and opens a new one,
  so a snapshot built `as_of` its knowledge cutoff resolves the binding that was valid then.
  There is no `current` flag and no superseded chain. Reads and writes are as of one
  instant; nothing here writes as of another.

  Organization-owned configuration: it carries no owner, and reading or writing it takes a
  role grant. Rows are never soft-deleted (`archival?: false`); `unbind` closes the period.

  A run names its binding by id with no database foreign key: the binding's key is
  `(id, valid_at)`, which an ordinary table cannot reference, so the run's `binding_id` is
  checked when the run is requested and again, as of its knowledge cutoff, when it is
  prepared (`AshEnterprise.Planning.Changes.PinModel`). The version a run uses is
  `AshEnterprise.Planning.Run.resolve_binding/1`: as of the cutoff, never the live one.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Planning,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    fragments: [AshPlanning.Fragment.Binding]

  postgres do
    table "planning_bindings"
    repo AshEnterprise.Repo
  end
end

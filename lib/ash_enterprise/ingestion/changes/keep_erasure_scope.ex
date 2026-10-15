defmodule AshEnterprise.Ingestion.Changes.KeepErasureScope do
  @moduledoc """
  A landing never moves a row to another erasure scope (ADR 0024).

  `SourceObject.land` upserts on `(external_system, external_id)`, which does
  not include the scope. Without this change a second connection landing the
  same pair would take the row over and re-seal it under its own key, so which
  shred reached the row would depend on sync order. Instead the upsert is
  conditional on the existing row naming the *same* scope: re-landing under the
  same scope refreshes the row in place (idempotency is unchanged), and a
  landing under a different scope matches no row to update and fails with
  `Ash.Error.Changes.StaleRecord` — leaving the existing row, its scope and its
  ciphertext exactly as they were.

  The condition is part of the `INSERT ... ON CONFLICT ... DO UPDATE ... WHERE`
  statement itself, so two connections racing to land the same pair cannot
  both win.

  Adapters avoid the conflict by construction: every Integration vertical
  namespaces `external_id` by the linked account it fetched through.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :erasure_scope_id) do
      nil ->
        changeset

      scope_id ->
        Ash.Changeset.filter(changeset, Ash.Expr.expr(erasure_scope_id == ^scope_id))
    end
  end
end

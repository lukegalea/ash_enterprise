defmodule AshEnterprise.Erasure do
  @moduledoc """
  Erasure by crypto-shredding — the erasure half of ADR 0024.

  Content that must be erasable is sealed, at the moment it is written, under
  the key of the **erasure scope** it belongs to (`AshEnterprise.Erasure.Scope`
  says what a scope is and why). Erasing is destroying that one key
  (`shred_scope/4`). Every row survives, every structural fact survives, the
  audit hash chain survives untouched — and every sealed value under the scope,
  including the ciphertext that reached the audit log, reads back as
  `AshEnterprise.Erasure.Shredded` from then on.

  ## For an ingestion adapter: land a record under a scope

      scope =
        AshEnterprise.Erasure.ensure_scope!(:connection, linked_account_ref,
          %{label: "VendorPM company Slack"},
          actor: AshEnterprise.Platform.SystemActor.oban()
        )

      AshEnterprise.Ingestion.SourceObject.land_under!(
        scope.id,
        %{
          external_system: "slack",
          external_id: "\#{team_id}/\#{channel_id}/\#{ts}",
          raw_payload: message,
          fetched_at: now
        },
        authorize?: false
      )

  Qualify `external_id` so it is unique across every connection that lands into
  the same `external_system` (a Slack `ts` alone is not unique across channels
  or workspaces). The landing identity is `[external_system, external_id]` and
  does not include the scope: a second connection landing the same pair is
  refused (`Ash.Error.Changes.StaleRecord`), and the row stays under the scope
  it first landed under. Provider syncs land through
  `AshEnterprise.Integration.Landing`, which does all of this per linked
  account.

  Resolve the scope once per connection (per run, per linked account), not per
  record: `ensure_scope` is a lookup after the first call, but it is still a
  query.

  Projectors copy `erasure_scope_id` from the SourceObject onto every canonical
  row they derive from it, so the canonical copy is sealed under the same key.

  ## For an operator: shred a scope

      mix ash_enterprise.erasure.scopes
      mix ash_enterprise.erasure.shred connection:<ref> --as you@example.com \\
        --reason "left VendorPM"

  or, from IEx, as a human actor holding a write grant on erasure scopes:

      scope = AshEnterprise.Erasure.scope_by_ref!(:connection, ref, authorize?: false)
      AshEnterprise.Erasure.shred_scope!(scope, ref, "left VendorPM", actor: user)

  Shredding stops nothing from arriving. Delete or revoke the provider
  connection (the Nango connection and the linked account) as well; a shredded
  scope then refuses anything that still lands under it, loudly.

  See `docs/runbooks/crypto-shredding.md` for the full procedure and for what a
  key destroy does **not** reach.
  """

  use Ash.Domain

  resources do
    resource AshEnterprise.Erasure.Scope do
      define :ensure_scope, action: :ensure, args: [:kind, :ref]
      define :open_scope, action: :open
      define :get_scope, action: :read, get_by: [:id]
      define :scope_by_ref, action: :by_ref, args: [:kind, :ref], not_found_error?: false
      define :list_scopes, action: :read
      define :shred_scope, action: :shred, args: [:confirm, :reason]
    end

    resource AshEnterprise.Erasure.Key
  end
end

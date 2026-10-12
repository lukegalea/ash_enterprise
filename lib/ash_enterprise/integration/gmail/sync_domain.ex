defmodule AshEnterprise.Integration.Gmail.SyncDomain do
  @moduledoc """
  The Gmail vertical's resources (epic E4): the per-linked-account sync cursor
  (`AshEnterprise.Integration.Gmail.SyncState`) and the one Gmail operation the
  backfill needs that the edge does not yet declare
  (`AshEnterprise.Integration.Gmail.MessageList`).

  A separate domain only because `AshEnterprise.Integration` (the edge's
  domain file) is not this change's to edit. Folding these two resources into
  that domain and deleting this module is an integration step; nothing outside
  `lib/ash_enterprise/integration/gmail/` names this module.

  `validate_config_inclusion?: false` for the same reason the edge's domain
  carries it: `config :ash_enterprise, :ash_domains` is owned by a concurrent
  change.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Integration.Gmail.SyncState
    resource AshEnterprise.Integration.Gmail.MessageList
  end
end

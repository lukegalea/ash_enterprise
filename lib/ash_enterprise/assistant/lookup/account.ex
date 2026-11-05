defmodule AshEnterprise.Assistant.Lookup.Account do
  @moduledoc """
  One of the person's own linked accounts: which provider, how its sync stands, and
  its `id` for `sync_account`.

  Computed, never stored: `my_accounts` is a manual read
  (`AshEnterprise.Assistant.Lookups.Accounts`) over the person's own linked accounts,
  made as the person, behind the zone gate. See `AshEnterprise.Assistant.Lookup`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:my_accounts],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :id, :uuid, public?: true
    attribute :provider, :string, public?: true
    attribute :label, :string, public?: true
    attribute :health, :string, public?: true
    attribute :last_sync, :string, public?: true
  end

  actions do
    read :my_accounts do
      description "The person's own linked accounts."
      manual Lookups.Accounts
    end
  end

  effects do
    action :my_accounts,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

defmodule AshEnterprise.Assistant.Lookup.Duplicate do
  @moduledoc """
  A possible duplicate (match candidate) waiting for the person's steward verdict.

  Computed, never stored: `steward_queue` is a manual read
  (`AshEnterprise.Assistant.Lookups.StewardQueue`) over the canonical reads, made
  as the person, behind the zone gate. See `AshEnterprise.Assistant.Lookup`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:steward_queue],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :incoming, :string, public?: true
    attribute :incoming_email, :string, public?: true
    attribute :existing, :string, public?: true
    attribute :existing_email, :string, public?: true
    attribute :score, :string, public?: true
    attribute :merge_keeps_name_of, :string, public?: true
    attribute :merge_keeps_email_of, :string, public?: true
    attribute :waiting_since, :string, public?: true
    attribute :may_decide, :boolean, public?: true
  end

  actions do
    read :steward_queue do
      description "Duplicates (match candidates) waiting for the person's steward verdict."
      manual Lookups.StewardQueue
    end
  end

  effects do
    action :steward_queue,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

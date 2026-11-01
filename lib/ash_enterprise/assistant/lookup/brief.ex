defmodule AshEnterprise.Assistant.Lookup.Brief do
  @moduledoc """
  One of the person's morning briefs, cited by `ref`.

  Computed, never stored: `morning_briefs` is a manual read
  (`AshEnterprise.Assistant.Lookups.Briefs`) over the canonical reads, made
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
    self_service: [:morning_briefs],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :day, :string, public?: true
    attribute :status, :atom, public?: true
    attribute :summary, :string, public?: true
    attribute :text, :string, public?: true
  end

  actions do
    read :morning_briefs do
      description "Recent morning briefs."

      argument :days, :integer do
        allow_nil? true
        description "How many recent briefs, 1 to 14. Default 3."
      end

      manual Lookups.Briefs
    end
  end

  effects do
    action :morning_briefs,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

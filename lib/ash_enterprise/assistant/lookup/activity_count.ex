defmodule AshEnterprise.Assistant.Lookup.ActivityCount do
  @moduledoc """
  A count over a window: the `all` row first (the total, its window, whether it was truncated), then one per group.

  Computed, never stored: `count_activity` is a manual read
  (`AshEnterprise.Assistant.Lookups.ActivityCounts`) over the canonical reads, made
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
    self_service: [:count_activity],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :key, :string, public?: true
    attribute :count, :integer, public?: true
    attribute :window, :string, public?: true
    attribute :truncated, :boolean, public?: true
  end

  actions do
    read :count_activity do
      description "Counts of messages, events or conversations over a window."

      argument :metric, :atom do
        allow_nil? false
        constraints one_of: [:messages, :events, :conversations]
        description "What to count: messages, events or conversations."
      end

      argument :group_by, :atom do
        allow_nil? false
        constraints one_of: [:person, :day, :source]
        description "person (sender or attendee), day or source (gmail, slack, calendar)."
      end

      argument :window, :string do
        allow_nil? true
        description Lookups.Support.window_help() <> " Default last_30_days."
      end

      manual Lookups.ActivityCounts
    end
  end

  effects do
    action :count_activity,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

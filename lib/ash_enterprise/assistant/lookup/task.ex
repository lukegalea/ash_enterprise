defmodule AshEnterprise.Assistant.Lookup.Task do
  @moduledoc """
  One of the person's own tasks or action items.

  Computed, never stored: `my_tasks` is a manual read
  (`AshEnterprise.Assistant.Lookups.Tasks`) over the canonical reads, made
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
    self_service: [:my_tasks],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :id, :uuid, public?: true
    attribute :title, :string, public?: true
    attribute :status, :atom, public?: true
    attribute :due, :string, public?: true
    attribute :source, :string, public?: true
  end

  actions do
    read :my_tasks do
      description "The person's own tasks and action items."

      argument :status, :atom do
        allow_nil? true
        constraints one_of: [:open, :done, :any]
        description "open, done or any. Default open."
      end

      manual Lookups.Tasks
    end
  end

  effects do
    action :my_tasks,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

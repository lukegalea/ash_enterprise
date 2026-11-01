defmodule AshEnterprise.Assistant.Lookup.Approval do
  @moduledoc """
  A process task waiting on the person, with the decisions its step takes.

  Computed, never stored: `pending_approvals` is a manual read
  (`AshEnterprise.Assistant.Lookups.Approvals`) over the canonical reads, made
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
    self_service: [:pending_approvals],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :task, :string, public?: true
    attribute :about, :string, public?: true
    attribute :outline, :string, public?: true
    attribute :status, :atom, public?: true
    attribute :decisions, {:array, :string}, public?: true
    attribute :waiting_since, :string, public?: true
    attribute :due, :string, public?: true
  end

  actions do
    read :pending_approvals do
      description "Process tasks waiting on the person."
      manual Lookups.Approvals
    end
  end

  effects do
    action :pending_approvals,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

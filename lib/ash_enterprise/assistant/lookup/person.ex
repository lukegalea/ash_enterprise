defmodule AshEnterprise.Assistant.Lookup.Person do
  @moduledoc """
  A contact as the person may read them, cited by `ref`; `records_then` only as of a past moment.

  Computed, never stored: `find_people` is a manual read
  (`AshEnterprise.Assistant.Lookups.People`) over the canonical reads, made
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
    self_service: [:find_people],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :name, :string, public?: true
    attribute :email, :string, public?: true
    attribute :conversations, :integer, public?: true
    attribute :next_event, :string, public?: true
    attribute :records_then, {:array, :map}, public?: true
  end

  actions do
    read :find_people do
      description "People by name or email."

      argument :query, :string do
        allow_nil? false
        description "Part of a name or email address."
      end

      argument :as_of, :string do
        description "A past moment to answer for: a date (2026-10-16, meaning the end of " <>
                      "that day) or a UTC time (2026-10-16T09:00:00Z). With it, each person " <>
                      "shows the separate records they were split across then, before or " <>
                      "after a merge."
      end

      manual Lookups.People
    end
  end

  effects do
    action :find_people,
      kind: :search,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

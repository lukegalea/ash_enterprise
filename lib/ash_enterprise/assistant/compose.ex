defmodule AshEnterprise.Assistant.Compose do
  @moduledoc """
  The assistant's `compose_surface` tool, as a computed read
  (`AshEnterprise.Assistant` declares it a tool): one row, saying what was
  shown. A read, so a run takes it in its loop (`AshEnterprise.Assistant.Lookup`).

  The model asks for a table, a calendar or a board of the person's own
  records; `AshEnterprise.Assistant.Composer` writes the spec from a curated
  catalogue and resolves it against the host allowlist through
  `AshA2ui.Dynamic.resolve/2`. The tool answers the model with what was shown
  (or short reasons it was not); the request rides in the row's `surface`,
  which the page reads off the run's journal (`AshEnterprise.Assistant.Ask`),
  which composes it again as the person and renders it inline in the turn
  (`AshEnterpriseWeb.AssistantLive`). The model never sees a row through this
  tool, and the surface it describes has no form or row action.

  Self-service (ADR 0052) and zone-gated like the read tools: it reads
  nothing itself, but it answers only the in-zone assistant.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:compose_surface],
    extra_extensions: [AshAgent.Effects]

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :shown, :string, public?: true
    attribute :covers, :string, public?: true
    attribute :surface, :map, public?: true
    attribute :notes, {:array, :string}, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    read :compose_surface do
      description "Show the person a table, calendar or board of their own records."

      argument :show, :atom do
        allow_nil? false

        constraints one_of: [
                      :events,
                      :tasks,
                      :conversations,
                      :messages,
                      :people,
                      :briefs,
                      :approvals,
                      :drafts
                    ]

        description "What to show: events, tasks, conversations, messages, people, briefs, " <>
                      "approvals or drafts (the person's reply drafts)."
      end

      argument :display, :atom do
        allow_nil? true
        constraints one_of: [:table, :calendar, :board]

        description "table (default), calendar (events, tasks, messages, briefs, approvals) or " <>
                      "board (lanes by status; messages by direction; conversations by kind)."
      end

      argument :window, :string do
        allow_nil? true

        description "Which days: today, tomorrow, this_week, next_week, upcoming, a weekday " <>
                      "(monday: the coming one, so pass the name, not a date), a date " <>
                      "(2026-10-19) or a range (2026-10-19..2026-10-25). Cuts a table to " <>
                      "those days; opens a calendar on them."
      end

      argument :status, :atom do
        allow_nil? true
        constraints one_of: [:open, :done, :any]
        description "Tasks only: open, done or any. Default any."
      end

      argument :channel, :atom do
        allow_nil? true
        constraints one_of: [:gmail, :slack, :any]
        description "Conversations only: gmail, slack or any."
      end

      argument :columns, {:array, :string} do
        allow_nil? true
        description "Optional columns, in order. Leave out for the usual ones."
      end

      argument :title, :string do
        allow_nil? true
        constraints max_length: 80
        description "A short heading for the person."
      end

      manual AshEnterprise.Assistant.Tools.ComposeSurface
    end
  end

  # The assistant's `compose_surface` tool (ADR 0057): it describes a surface
  # and changes nothing.
  effects do
    action :compose_surface,
      kind: :think,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose
  end
end

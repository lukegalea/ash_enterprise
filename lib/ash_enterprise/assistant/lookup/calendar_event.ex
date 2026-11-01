defmodule AshEnterprise.Assistant.Lookup.CalendarEvent do
  @moduledoc """
  A calendar event as the person may read it, cited by `ref`.

  Computed, never stored: `calendar_events` is a manual read
  (`AshEnterprise.Assistant.Lookups.CalendarEvents`) over the canonical reads, made
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
    self_service: [:calendar_events],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :title, :string, public?: true
    attribute :when, :string, public?: true
    attribute :where, :string, public?: true
    attribute :organizer, :string, public?: true
    attribute :attendees, {:array, :string}, public?: true
    attribute :attendee_count, :integer, public?: true
    attribute :status, :atom, public?: true
    attribute :now, :string, public?: true
    attribute :status_now, :atom, public?: true
  end

  actions do
    read :calendar_events do
      description "Calendar events in a window, by attendee or text, now or as of a past moment."

      argument :window, :string do
        allow_nil? true
        description Lookups.Support.window_help() <> " Default this_week."
      end

      argument :attendee, :string do
        allow_nil? true
        description "A name or email of someone attending or organizing."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the event title or location."
      end

      argument :as_of, :string do
        allow_nil? true

        description "A past moment to answer for: a date (2026-10-16, meaning the end of " <>
                      "that day) or a UTC time. With it, the events as they were known " <>
                      "then, before any later reschedule or cancellation; an event that " <>
                      "has changed since carries now or status_now."
      end

      manual Lookups.CalendarEvents
    end
  end

  effects do
    action :calendar_events,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end

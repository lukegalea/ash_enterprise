defmodule AshEnterprise.Assistant.Lookup do
  @moduledoc """
  The assistant's read tools, as generic actions (`AshEnterprise.Assistant`
  declares each one a tool).

  ## Why generic actions over the canonical reads

  A read action exposed as a tool hands the model Ash's whole filter and
  sort vocabulary — a schema far too large for a ~27B model to use well, and
  one that cannot filter sealed attributes (they are ciphertext in the
  database). Each action here takes one to four small arguments, runs the
  canonical model's own read actions **as the calling person**
  (`authorize?: true`, owner-only rows and all), and answers with a compact
  map: a `count`, the rows a model needs with a `ref` it can cite, and
  nothing else. Sealed content is decrypted only by those reads, for its
  owner (`decrypt_by_default`); there is no other decryption path here.

  Self-service (ADR 0052): any active member may ask, for themselves. Nothing
  is row access at this level — every row comes out of a read filtered as
  them — and each action also passes the zone gate
  (`AshEnterprise.Assistant.ZoneGate`) before it reads anything.

  No rows, no data layer, nothing written.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [
      :calendar_events,
      :find_conversations,
      :read_messages,
      :find_people,
      :my_tasks,
      :morning_briefs,
      :pending_approvals,
      :steward_queue,
      :count_activity
    ]

  alias AshEnterprise.Assistant.Lookups

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check (as on Agents.Console).
  resource do
    require_primary_key? false
  end

  @window "A time window: today, tomorrow, yesterday, this_week, next_week, next_7_days, " <>
            "next_30_days, last_7_days, last_30_days, last_90_days, upcoming, a weekday " <>
            "(monday: the coming one), a date (2026-10-14) or a range (2026-10-01..2026-10-14)."

  actions do
    action :calendar_events, :map do
      description "Calendar events in a window, by attendee or text."

      argument :window, :string do
        allow_nil? true
        description @window <> " Default this_week."
      end

      argument :attendee, :string do
        allow_nil? true
        description "A name or email of someone attending or organizing."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the event title or location."
      end

      run Lookups.CalendarEvents
    end

    action :find_conversations, :map do
      description "Email threads and Slack conversations, newest first."

      argument :source, :atom do
        allow_nil? true
        constraints one_of: [:gmail, :slack, :any]
        description "gmail, slack or any. Default any."
      end

      argument :person, :string do
        allow_nil? true
        description "A name or email of someone taking part."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the subject or the messages."
      end

      argument :window, :string do
        allow_nil? true
        description @window <> " Default: any time."
      end

      argument :needs_reply, :boolean do
        allow_nil? true
        description "true: only threads whose latest message is from someone else."
      end

      run Lookups.Conversations
    end

    action :read_messages, :map do
      description "Messages, newest first, in one conversation or across all."

      argument :conversation, :string do
        allow_nil? true
        description "A conversation's ref (inbox:… or slack:…) from find_conversations."
      end

      argument :person, :string do
        allow_nil? true
        description "A sender's name or email."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the message."
      end

      argument :window, :string do
        allow_nil? true
        description @window <> " Default last_30_days, or any time within one conversation."
      end

      run Lookups.Messages
    end

    action :find_people, :map do
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

      run Lookups.People
    end

    action :my_tasks, :map do
      description "The person's own tasks and action items."

      argument :status, :atom do
        allow_nil? true
        constraints one_of: [:open, :done, :any]
        description "open, done or any. Default open."
      end

      run Lookups.Tasks
    end

    action :morning_briefs, :map do
      description "Recent morning briefs."

      argument :days, :integer do
        allow_nil? true
        description "How many recent briefs, 1 to 14. Default 3."
      end

      run Lookups.Briefs
    end

    action :pending_approvals, :map do
      description "Process tasks waiting on the person."
      run Lookups.Approvals
    end

    action :steward_queue, :map do
      description "Duplicates (match candidates) waiting for the person's steward verdict."
      run Lookups.StewardQueue
    end

    action :count_activity, :map do
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
        description @window <> " Default last_30_days."
      end

      run Lookups.ActivityCounts
    end
  end
end

defmodule AshEnterprise.Agents.MorningBrief do
  @moduledoc """
  The subject of the morning-brief BPMN process (Productivity OS Dogfood epic
  E5; dogfood §6/§11): one row per `(owner, brief_date)`, carried through the
  `morning.brief` process as its subject.

  The draft is a **deterministic template** over the day's
  `AshEnterprise.Canonical.CalendarEvent` rows — no LLM call. Summarization via
  the local model is the operator's deferred decision; when it arrives it will
  be another approved step in the process, not a change to this resource's
  contract.

  `status` is the approval ledger: `:pending_approval` while the human task is
  open, then exactly one of `:approved` / `:rejected`, set by the actions the
  process's service tasks invoke (through
  `AshEnterprise.Process.ActionInvoker`'s registry — the diagram names the
  composition; the allowlist here is what makes that invocation reviewed code).

  ## Erasure (ADR 0024)

  The draft is **rendered on read**, never stored. The compose step records
  which events it selected (`event_ids`); `draft_text` is a calculation that
  renders them. Event titles and locations are sealed under their connection's
  erasure scope, so a stored copy of the rendered text would be plaintext in
  this row and in the compose's audit event (which ash_events records from
  every changed attribute) that no shred could reach. Rendering on read keeps
  each line under its own event's key: after a shred it reads `[shredded]`,
  and a brief that spans several connections shreds line by line.

  The trade: an approved brief re-renders from the events as they are now. A
  later sync that renames an event changes the brief's text; the set of
  events and the decision on it do not change.

  `lifecycle?`/`archival?` are opted out for the same reasons as
  `AshEnterprise.Agents.AgentRun`: `status` is the lifecycle, and a decided
  brief is history, not soft-deleted data.

  ## How a brief comes to exist

  `compose_today` is the one entry point: it opens the owner's brief for the
  day and starts `morning.brief` with it as subject, in one transaction
  (`AshEnterprise.Agents.Actions.ComposeToday`). Two callers use it, both as
  the owner: the daily scheduler (`AshEnterprise.Agents.MorningBriefScheduler`,
  06:30 on the display zone's clock) and the operator on demand (Today's
  Compose button, the ACP `compose brief` prompt). One brief per owner per
  day (`one_per_owner_per_day`); there is no recompose — the process has no
  path back from its approval task to its compose step. See
  `docs/runbooks/morning-brief.md`.

  ## Anyone may compose their own

  Composing, and opening and reading one's own briefs, are **self-service**
  (ADR 0052, `AshEnterprise.Security.Checks.SelfService`): any active member
  of the tenant may do them with no MorningBrief grant at all. `compose_today`
  is the actor's own by construction — it takes no owner, and the brief it
  opens is owned by the actor — and `start_for_date`, `read` and `latest`
  reach only rows the actor owns. There is no way through this resource to
  compose someone else's brief, and another member's brief stays out of reach
  unless a role grants it. Deciding a brief is the approval task's business
  (`AshEnterprise.Agents.BriefDecision`), under that task's own policies.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    lifecycle?: false,
    archival?: false,
    self_service: [:compose_today, :start_for_date, :read, :latest],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "agent_morning_briefs"
    repo AshEnterprise.Repo
  end

  # What keeps Today live: a brief composed by the scheduler, the compose step
  # landing its events, and the decision landing its status each refresh the
  # open page (`AshEnterprise.Surfaces.topics/1` reads these). The
  # broadcast carries no row; every page re-reads as its own actor.
  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "morning_briefs"

    publish_all :create, ["created"]
    publish_all :update, ["updated"]
  end

  attributes do
    uuid_primary_key :id

    attribute :brief_date, :date do
      allow_nil? false
      public? true

      description "The day the brief covers: a local day in the display zone (`LocalTime`)."
    end

    attribute :event_ids, {:array, :uuid} do
      public? true

      description """
      The canonical calendar events the compose step selected, as ids. Nil
      until the process's compose step runs; `[]` for a day with no events.
      """
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending_approval, :approved, :rejected]
      default :pending_approval

      description "pending_approval while the human task is open; terminal after the decision."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # The brief's events: the ids the compose step recorded (no join table —
    # the selection is the brief's own fact). Read as the reader, so an event
    # they cannot see is simply not there.
    has_many :events, AshEnterprise.Canonical.CalendarEvent do
      public? true
      no_attributes? true
      filter expr(id in parent(event_ids))
      sort starts_at: :asc
      description "The calendar events the brief covers, in start order."
      temporal_keys {nil, :valid_at}
    end

    # Its approval: the human task of the `morning.brief` process run with this
    # brief as subject (the engine records the subject on the instance).
    has_one :approval_task, AshEnterprise.Bpmn.HumanTask do
      public? true
      no_attributes? true

      filter expr(
               instance.subject_type == "Elixir.AshEnterprise.Agents.MorningBrief" and
                 instance.subject_id == parent(id)
             )

      sort inserted_at: :desc
      description "The approval task deciding this brief."
    end

    # The `morning.brief` run itself: what Today's "Where it stands" link
    # opens on its flight view. Read as the reader, like any instance.
    has_one :process_run, AshEnterprise.Bpmn.Instance do
      public? true
      no_attributes? true

      filter expr(
               subject_type == "Elixir.AshEnterprise.Agents.MorningBrief" and
                 subject_id == parent(id)
             )

      sort inserted_at: :desc
      description "The process run composing and deciding this brief."
    end
  end

  identities do
    # Per tenant (attribute multitenancy adds `organization_id`): what makes
    # the scheduler and the Compose button idempotent, and a double click a
    # refusal rather than a second approval task.
    identity :one_per_owner_per_day, [:owner_id, :brief_date] do
      message "you already have a morning brief for that day"
    end
  end

  actions do
    defaults [:read]

    create :start_for_date do
      description """
      Opens a brief for one date. Starting the BPMN process with this row as
      its subject is what composes and routes it; this action only creates the
      subject.
      """

      accept [:brief_date]

      change set_attribute(:owner_id, actor(:id))
    end

    action :compose_today, :string do
      description """
      Compose the actor's morning brief: open it for the day and start the
      `morning.brief` process with it as subject, in one transaction. A day
      that already has the actor's brief is left alone and reported (there is
      no recompose). Returns a status line.
      """

      transaction? true

      argument :brief_date, :date do
        allow_nil? true

        description """
        The day to brief. Defaults to today on the display zone's clock; the
        scheduler pins the day it scheduled, so a job that runs late does not
        brief the wrong day.
        """
      end

      run AshEnterprise.Agents.Actions.ComposeToday
    end

    update :compose_brief do
      description """
      Selects the canonical calendar events for `brief_date` and records their
      ids; `draft_text` renders them on read. Invoked by the process's service
      task; no LLM.
      """

      accept []

      change AshEnterprise.Agents.Changes.ComposeDraft
    end

    read :latest do
      description "The actor's own most recent brief: what the Today surface leads with."
      prepare AshEnterprise.Agents.Preparations.OwnBriefs
    end

    # The Today surface's reports and the ACP `today` digest: reads as the
    # calling actor over calendar, approvals, syncs and inbox — see
    # `AshEnterprise.Agents.Today`. Nothing here writes.
    action :agenda, {:array, :map} do
      description "Today's calendar events as report rows (time, title, where, status)."
      run {AshEnterprise.Agents.Actions.TodayReport, report: :agenda}
    end

    action :pulse, {:array, :map} do
      description "The day's signals as report rows: approvals, next event, sync health, inbox."
      run {AshEnterprise.Agents.Actions.TodayReport, report: :pulse}
    end

    update :approve do
      description "The human task's `approved` outcome lands here."
      accept []

      change set_attribute(:status, :approved)
    end

    update :reject do
      description "The human task's `rejected` outcome lands here."
      accept []

      change set_attribute(:status, :rejected)
    end
  end

  calculations do
    calculate :headline,
              :string,
              {AshEnterprise.Platform.Calculations.LocalStamp, field: :brief_date} do
      public? true
      description "The brief's day, `Mon 12 Oct`."
    end

    calculate :summary, :string, AshEnterprise.Agents.Calculations.BriefSummary do
      public? true
      description "The brief in one line: event count, span and cancellations. No titles."
    end

    calculate :draft_text, :string, AshEnterprise.Agents.Calculations.RenderDraft do
      public? true

      description """
      The draft, rendered on read from `event_ids` by `render/2`. Nil until the
      compose step runs. Never stored: see the moduledoc's erasure note.
      """
    end
  end

  code_interface do
    define :start_for_date, args: [:brief_date]
    define :compose_today
    define :compose_brief
    define :approve
    define :reject
  end

  @doc """
  The deterministic template. `render/2` is public so the process's only
  creative act is visible and testable: a date header, one line per event
  (times and title, location when the event says where), and an explicit
  no-events fallback — never silence.
  """
  def render(date, []), do: "Morning brief for #{Date.to_iso8601(date)}\n\nNo events scheduled."

  def render(date, events) do
    lines =
      events
      |> Enum.map_join("\n", fn event ->
        "#{format_time(event.starts_at)}–#{format_time(event.ends_at)}  #{event.title}" <>
          location_suffix(event.location)
      end)

    "Morning brief for #{Date.to_iso8601(date)}\n\n#{lines}"
  end

  # The operator's wall clock (`AshEnterprise.Platform.LocalTime`), the same
  # zone the brief's day is cut in.
  defp format_time(datetime), do: AshEnterprise.Platform.LocalTime.time(datetime)

  defp location_suffix(nil), do: ""
  defp location_suffix(location), do: "  (#{location})"
end

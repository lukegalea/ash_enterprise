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

  `lifecycle?`/`archival?` are opted out for the same reasons as
  `AshEnterprise.Agents.AgentRun`: `status` is the lifecycle, and a decided
  brief is history, not soft-deleted data.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    lifecycle?: false,
    archival?: false

  postgres do
    table "agent_morning_briefs"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :brief_date, :date do
      allow_nil? false
      public? true

      description "The day the brief covers, in UTC."
    end

    attribute :draft_text, :string do
      public? true
      constraints max_length: 32_768

      description "The composed draft. Nil until the process's compose step runs."
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

    update :compose_brief do
      description """
      Composes the deterministic draft for `brief_date` from today's canonical
      calendar events. Invoked by the process's service task; no LLM.
      """

      accept []

      change AshEnterprise.Agents.Changes.ComposeDraft
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

  code_interface do
    define :start_for_date, args: [:brief_date]
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

  defp format_time(datetime), do: Calendar.strftime(datetime, "%H:%M")

  defp location_suffix(nil), do: ""
  defp location_suffix(location), do: "  (#{location})"
end

defmodule AshEnterprise.Canonical.Commitments do
  @moduledoc """
  Commitments the person made, proposed as action items they accept (PROD-18;
  ADR 0047: learning produces proposals, never silent writes).

  Two proposers, one sweep (`sweep/1`, run by `SweepWorker` on a cron):

    * **`message_commitments/1`** reads each message the person **sent** in
      the last #{7} days — Gmail and Slack alike — and asks the in-zone model
      for the things they promised to do ("I'll send it by Friday"): an
      action, the words it came from, and a due date when the message gives
      one (`AshEnterprise.Canonical.Commitments.ModelExtractor`).
    * **`meeting_follow_ups/1`** proposes a follow-up for each meeting with
      other people that ended in the last #{2} days. Deterministic: no model,
      the meeting's title is the whole input.

  ## A proposal, never a decision

  Each finding becomes a `Canonical.Task` in status `:proposed`, owned by the
  person, in the Proposed lane of their Action items board. It is not on any
  list until they **Accept** it (`Task.accept_mine`), and **Dismiss**
  (`Task.dismiss_mine`) ends it. Both are the person's own acts: the
  updates behind them refuse any actor that is not a person, so the
  proposer cannot accept what it proposed. The proposer is the
  `:proposer` system actor; it writes proposals and scan records and
  nothing else. Every read gets a `Canonical.CommitmentScan` — the proposer,
  the instrument and how many it found, zero included — written in the same
  transaction, so each record is read once.

  ## Content (ADRs 0024 and 0042)

  The words of a proposal are canonical content: `commitment` and `evidence`
  are sealed under the erasure scope of the message or meeting they came
  from, so shredding that connection leaves `[shredded]` in their place.

  A message's text goes only to the operator's in-zone generative profile,
  and only when it runs in the canonical store's zone
  (`AshEnterprise.Assistant.ZoneGate`). With no such target nothing is sent,
  nothing is scanned, and the messages wait for one: never a hosted model.
  Meeting follow-ups need no model and are proposed either way.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.AI.Models
  alias AshEnterprise.Assistant.ZoneGate
  alias AshEnterprise.Canonical.{CalendarEvent, CommitmentScan, Message, Task}
  alias AshEnterprise.Platform.{LocalTime, SystemActor}

  @message_days 7
  @meeting_days 2
  @batch 25
  @max_per_record 3

  @message_proposer "message_commitments/1"
  @meeting_proposer "meeting_follow_ups/1"

  @typedoc "What one sweep did: how many messages and meetings it read, how many it proposed."
  @type result :: %{
          messages: non_neg_integer(),
          meetings: non_neg_integer(),
          proposed: non_neg_integer(),
          skipped: atom() | nil
        }

  @doc """
  One sweep over every tenant: up to #{@batch} unread sent messages and #{@batch}
  unread ended meetings. Options: `:now` (the clock, for tests) and
  `:extractor` (the message extractor module; default from config, else
  `ModelExtractor`).
  """
  @spec sweep(keyword()) :: result()
  def sweep(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    {messages, proposed_m, skipped} = message_commitments(Keyword.put(opts, :now, now))
    {meetings, proposed_e} = meeting_follow_ups(Keyword.put(opts, :now, now))

    %{
      messages: messages,
      meetings: meetings,
      proposed: proposed_m + proposed_e,
      skipped: skipped
    }
  end

  @doc """
  Reads the unread sent messages with the in-zone model and proposes what
  they promised. `{read, proposed, skipped}`; `skipped` names why nothing was
  read (`:outside_zone`, `:zone_mismatch`, `:no_model_target`).
  """
  def message_commitments(opts) do
    target = Models.resolve(Models.default_spec())

    case ZoneGate.check(target) do
      :ok ->
        extractor = Keyword.get(opts, :extractor, extractor())

        {read, proposed} =
          opts[:now]
          |> unread_messages()
          |> tally(&scan_message(&1, target, extractor))

        {read, proposed, nil}

      {:error, reason} ->
        {0, 0, reason}
    end
  end

  @doc "Proposes a follow-up for each unread meeting with others that has ended. `{read, proposed}`."
  def meeting_follow_ups(opts) do
    opts[:now]
    |> unread_meetings()
    |> tally(&scan_meeting/1)
  end

  # `{read, proposed}` over the records `scan` was run on; a record to retry
  # counts as neither.
  defp tally(records, scan) do
    Enum.reduce(records, {0, 0}, fn record, {read, proposed} ->
      case scan.(record) do
        {:ok, found} -> {read + 1, proposed + found}
        :retry -> {read, proposed}
      end
    end)
  end

  @doc "The extractor module: `config :ash_enterprise, #{inspect(__MODULE__)}, extractor: Module`."
  def extractor do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:extractor, __MODULE__.ModelExtractor)
  end

  # -- messages --------------------------------------------------------------

  @message_type to_string(Message)
  @event_type to_string(CalendarEvent)

  # The proposer reads as the system: every tenant, every owner. What it
  # reads is the person's own mail, and what it writes is theirs.
  defp unread_messages(now) do
    since = DateTime.add(now, -@message_days, :day)

    Message
    |> Ash.Query.filter(
      direction == :outbound and sent_at > ^since and sent_at <= ^now and
        not exists(CommitmentScan, source_type == ^@message_type and source_id == parent(id))
    )
    |> Ash.Query.sort(sent_at: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(authorize?: false)
  end

  defp scan_message(%Message{body: body} = message, target, extractor) do
    if is_binary(body) and String.trim(body) != "" do
      input = %{text: body, sent_at: message.sent_at, system: message.external_system}
      extractor.extract(input, target) |> extracted(message, target)
    else
      # Shredded, or nothing to read: scanned, nothing found.
      record(message, @message_type, [], @message_proposer, instrument(target))
    end
  end

  defp extracted({:ok, found}, message, target) do
    proposals =
      found
      |> Enum.take(@max_per_record)
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} -> message_proposal(message, item, n) end)

    record(message, @message_type, proposals, @message_proposer, instrument(target))
  end

  # Not scanned: the message is read again on a later sweep.
  defp extracted({:error, reason}, message, _target) do
    Logger.warning("commitments: message #{message.id} not read (#{Models.error_class(reason)})")
    :retry
  end

  defp message_proposal(message, item, n) do
    %{
      commitment: item.action,
      evidence: item[:quote],
      due_at: item[:due] && day_due(item.due),
      source: message.external_system,
      origin_type: to_string(AshEnterprise.Canonical.Conversation),
      origin_id: message.conversation_id,
      external_system: "commitment",
      external_id: "#{@message_type}:#{message.id}:#{n}",
      erasure_scope_id: message.erasure_scope_id,
      proposer: @message_proposer
    }
  end

  # -- meetings ----------------------------------------------------------------

  defp unread_meetings(now) do
    since = DateTime.add(now, -@meeting_days, :day)

    CalendarEvent
    |> Ash.Query.filter(
      status == :confirmed and ends_at > ^since and ends_at <= ^now and attendee_count > 1 and
        not exists(CommitmentScan, source_type == ^@event_type and source_id == parent(id))
    )
    |> Ash.Query.sort(ends_at: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(authorize?: false)
  end

  defp scan_meeting(%CalendarEvent{title: title} = event) do
    proposals =
      if is_binary(title) and String.trim(title) != "" do
        [
          %{
            commitment: "Follow up on #{title}",
            evidence: nil,
            due_at: nil,
            source: "calendar",
            origin_type: @event_type,
            origin_id: event.id,
            external_system: "commitment",
            external_id: "#{@event_type}:#{event.id}:1",
            erasure_scope_id: event.erasure_scope_id,
            proposer: @meeting_proposer
          }
        ]
      else
        # Shredded or untitled: nothing to follow up by name.
        []
      end

    record(event, @event_type, proposals, @meeting_proposer, "deterministic")
  end

  # -- writing -----------------------------------------------------------------

  # The proposals and their scan, together or not at all, as the proposer.
  # An identity conflict means a concurrent sweep got there first.
  defp record(source, type, proposals, proposer, instrument) do
    opts = [actor: SystemActor.proposer(), tenant: source.organization_id]
    owner = Map.take(source, [:owner_id, :owner_type, :owning_user_id, :owning_business_unit_id])

    [Task, CommitmentScan]
    |> Ash.transaction(fn ->
      Enum.each(proposals, fn proposal ->
        proposal
        |> Map.merge(Map.delete(owner, :owner_type))
        |> Map.put(:instrument, instrument)
        |> Task.propose!(opts)
      end)

      CommitmentScan.record!(
        Map.merge(owner, %{
          source_type: type,
          source_id: source.id,
          found: length(proposals),
          proposer: proposer,
          instrument: instrument
        }),
        opts
      )

      length(proposals)
    end)
    |> case do
      {:ok, found} -> {:ok, found}
      {:error, error} -> not_recorded(type, source, error)
    end
  rescue
    error -> not_recorded(type, source, error)
  end

  # Structural only: an error can echo the content it was handed.
  defp not_recorded(type, source, error) do
    Logger.warning(
      "commitments: #{type} #{source.id} not recorded (#{Models.error_class(error)})"
    )

    :retry
  end

  defp instrument(%{label: label, zone: zone}), do: "#{label} @ #{zone}"

  # Due at 17:00 on that day in the display zone.
  defp day_due(%Date{} = date) do
    {from, _to} = LocalTime.days(date, 1)
    DateTime.add(from, 17, :hour)
  end
end

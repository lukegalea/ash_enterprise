# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshEnterprise.SystemOne.FactReplay do
  @moduledoc """
  The §5.2 admission-ledger replay for the temporal facts host
  (`AshEnterprise.SystemOne.Fact`, AST-149): rebuild the periods by
  replaying the recorded decisions in `effective_at` order through the
  temporal materialiser.

  Facts are derived data — the migration is never SQL translation. The
  recorded decisions are the source of truth; replaying them in
  `effective_at` order through `AshJudgments.Facts.Materialiser`
  reconstructs correct periods (the replay-equivalence property,
  `materialise(clear+replay) ≡ materialise(live)`, is pinned by the
  package's AST-148 battery).

  ## Where this host's decisions live

  Every materialiser write on the facts table was audited
  (`AshEvents.Events` → `AshEnterprise.Audit.EventLog`) — "recorded never
  recomputed" (§6.1) means the audit log IS the decision sequence:

    * a `:materialise` CREATE carries the full fact payload in `data` —
      one `:admitted` decision at the event's `occurred_at`;
    * a `:supersede` UPDATE ends a fact's currency — one `:omitted`
      decision (omission supersedes, §7.2 n.4). The legacy path revised by
      supersede-then-create: the supersede truncates at t, the replacement
      create opens at t' — replaying BOTH decisions in order is exactly a
      temporal revise (and where no create followed, it is a true
      omission). No collapsing heuristic; the recorded sequence replays
      as recorded.

  Decisions that wrote nothing (`:review`, idempotent `:unchanged`,
  `:kept_person_fact`) left no events and leave no periods — absent from
  the log, absent from the replay, identical result.

  ## Legacy archive (design note §5.2: rename, don't drop)

  The cut-over migration archives the legacy table by rename. For
  standalone/ops use, `archive_legacy_table/1` renames a legacy facts
  table to `<name>_legacy_<utc>` — data preserved, never dropped.
  """

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Repo
  alias AshEnterprise.SystemOne.Fact
  alias AshJudgments.Facts.Materialiser

  @doc """
  Replays `decisions` (enumerable of decision maps — the materialiser's
  own input shape, plus `effective_at`) in `effective_at` order through
  the temporal materialiser. Returns
  `{:ok, %{replayed: count, materialised: n, unchanged: n,
  kept_person_fact: n, superseded: n, no_fact: n, no_prior_fact: n}}`.
  """
  def replay(decisions, opts \\ []) do
    resource = Keyword.get(opts, :resource) || facts_resource!()

    unless Ash.Resource.Info.temporal?(resource) do
      raise ArgumentError,
            "replay requires a TEMPORAL facts resource (the host must include " <>
              "AshJudgments.Facts.TemporalFragment) — replaying through the legacy " <>
              "fragment would rebuild final states, not periods"
    end

    sorted =
      decisions
      |> Enum.map(&Map.new/1)
      |> Enum.sort_by(&effective_at_instant/1, DateTime)

    tally =
      Enum.reduce(sorted, zero_tally(), fn decision, acc ->
        {:ok, verdict} = Materialiser.materialise(decision, resource: resource)

        Map.update!(acc, verdict, &(&1 + 1))
      end)

    {:ok, Map.put(tally, :replayed, length(sorted))}
  end

  @doc """
  Extracts the recorded decision sequence from the audit event log: every
  `:materialise` create and `:supersede` update ever written to the facts
  table, converted to the materialiser's decision shape with each event's
  `occurred_at` as `effective_at`. Sorted; ready for `replay/2`.
  """
  def decisions_from_event_log(opts \\ []) do
    # The event log's :atom columns deserialize only when the resources
    # that own the atoms are loaded (the mix-task boot discipline).
    Code.ensure_compiled(Fact)

    events =
      EventLog
      |> Ash.Query.filter(resource == ^Fact and action in [:materialise, :supersede])
      |> Ash.Query.sort([:occurred_at, :id])
      |> Ash.read!(authorize?: Keyword.get(opts, :authorize?, false))

    # Fold in time order, carrying each record's last create payload so a
    # :supersede (whose event data is only the superseder reference) can
    # name the subject/predicate/scope it ends.
    {decisions, _final} =
      Enum.map_reduce(events, %{}, fn event, payload_by_record ->
        case {event.action_type, event.action} do
          {:create, :materialise} ->
            # `data` is the action's input params (JSON round-tripped:
            # string keys); the event's occurred_at is the write's own
            # create timestamp (recorded_at), so the decision's
            # effective_at is the instant the fact actually took effect.
            payload = event.data || %{}

            decision =
              %{
                result: :admitted,
                subject: payload["subject"],
                predicate: payload["predicate"],
                value: payload["value"],
                holds: payload["holds"],
                scope: payload["scope"],
                subject_state_digest: payload["subject_state_digest"],
                valid_until: parse_dt(payload["valid_until"]),
                admission_grade: grade(payload["admission_grade"]),
                admission_id: payload["admission_id"],
                effective_at: event.occurred_at
              }

            {decision, Map.put(payload_by_record, event.record_id, payload)}

          {:update, :supersede} ->
            payload = Map.get(payload_by_record, event.record_id, %{})

            decision = %{
              result: :omitted,
              subject: payload["subject"],
              predicate: payload["predicate"],
              scope: payload["scope"],
              effective_at: event.occurred_at
            }

            {decision, payload_by_record}

          _other ->
            # A recorded write the decision vocabulary does not name — the
            # honest answer is to refuse loudly, not to guess.
            raise ArgumentError,
                  "unreplayable facts event: #{inspect(event.action_type)}/#{inspect(event.action)} " <>
                    "(record #{event.record_id} at #{event.occurred_at})"
        end
      end)

    {:ok, Enum.reject(decisions, &is_nil(&1.subject))}
  end

  @doc """
  Replays from a JSONL file (one decision per line — the admission-ledger
  wire shape); blank lines skipped.
  """
  def replay_file(path, opts \\ []) do
    decisions =
      path
      |> File.stream!()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)

    replay(decisions, opts)
  end

  @doc """
  §5.2 archive: renames a legacy facts table to `<name>_legacy_<utc>` —
  rename, never drop. Returns the archived name. (The AST-149 cut-over
  migration already archived this host's table; this helper is for
  standalone/ops use.)
  """
  def archive_legacy_table(table_name) when is_binary(table_name) do
    archived =
      "#{table_name}_legacy_" <> (System.system_time(:second) |> Integer.to_string())

    Repo.query!("ALTER TABLE #{table_name} RENAME TO #{archived}", [])

    archived
  end

  ## Decision conversion

  # Atoms round-tripping out of the event log exist (the resources are
  # loaded, and these two are the grade contract's whole vocabulary) —
  # String.to_existing_atom is the safe spelling regardless.
  defp grade("grant"), do: :grant
  defp grade("person"), do: :person
  defp grade(nil), do: nil
  defp grade(other) when is_atom(other), do: other

  defp parse_dt(nil), do: nil
  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp effective_at_instant(decision) do
    case decision[:effective_at] || decision["effective_at"] do
      %DateTime{} = dt ->
        dt

      other ->
        case parse_dt(other) do
          %DateTime{} = dt -> dt
          _ -> DateTime.utc_now()
        end
    end
  end

  defp zero_tally do
    %{
      materialised: 0,
      unchanged: 0,
      kept_person_fact: 0,
      superseded: 0,
      no_fact: 0,
      no_prior_fact: 0
    }
  end

  defp facts_resource! do
    case Application.get_env(:ash_judgments, :facts) do
      nil ->
        raise ArgumentError,
              "no facts resource configured; set config :ash_judgments, :facts to the host " <>
                "resource that includes AshJudgments.Facts.TemporalFragment"

      resource ->
        resource
    end
  end
end

defmodule AshEnterprise.Planning.SnapshotBuilder do
  @moduledoc """
  Prepares a `:pending` `AshEnterprise.Planning.Run` (ADR 0062): reads the declared inputs,
  lowers them to the model's data, seals the references-and-hashes envelope
  (`AshOpenLineage.Snapshot`) and records the result on the run's *preparation* axis.

      SnapshotBuilder.prepare(run) :: {:ok, %Run{}} | {:error, term}

  A run that is not `:pending` is returned unchanged, so a retried job is idempotent. The
  write is `Run.prepare` as the `oban` machinery actor, which is the only way the axis moves.

  ## Declared inputs (`personal_week`)

  Every input is read through a declared read action on the requester's own rows, in the
  run's tenant:

    * **tasks** — the requester's `Canonical.Task` rows in status `:open`. Unscheduled ones
      are what the solver places; one already scheduled inside the horizon is *pinned
      occupancy* (an earlier applied plan stands: replanning moves only what is unplaced);
      one scheduled outside the horizon is not an input.
    * **meetings** — the requester's `Canonical.CalendarEvent` rows overlapping the horizon
      and not cancelled, read **as of the run's `knowledge_cutoff`** (the calendar is
      temporal). A confirmed event is mandatory (priority 3); a tentative one is optional
      (priority 1).
    * **requirements** — the tenant's `canonical_planning.requirements` decision evaluated
      once per weekday. It is a *definition*, pinned into the snapshot by key, version and
      content hash; when the run's binding pins a different version or hash, preparation
      fails with `definition_drift` rather than planning against a decision nobody bound.

  The horizon is the UTC ISO week containing the knowledge cutoff; nothing is placed before
  the cutoff (`t_release`). The cutoff is taken once, on the first attempt, and reused.

  ## What is recorded

  Per input: `(resource, id, version_number, content_hash)` in `Snapshot.Input` (`source`
  and `content_hash`), plus the pinned definitions (the binding's selection, the decision,
  and the model version's model, checker and validator hashes). The whole envelope, with its
  digest, rides inside the sealed `problem_payload` under `"snapshot"` — references and
  hashes only, never values — so the apply flow and a replay read the sources back from the
  run. `Run.snapshot_digest` is the envelope's digest.

  ## Outcomes

    * `:prepared` — every input is a `:value`; the payload is sealed on the run.
    * `:needs_input` — at least one input is `:unresolved` (a task with no estimate),
      `:invalid` (a non-positive estimate) or `:missing_citation`; `unresolved_inputs`
      names each source (`id`, `resource`, `status`, `reason` code) and never a value. The
      snapshot digest is recorded; there is no problem, so no solve starts.
    * `:preparation_failed` — the binding, model version, decision or a read could not be
      resolved; the reason code is in `stats["reason"]`.

  Lowering itself lives in `AshEnterprise.Planning.Lowering`; this module does I/O.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.{CalendarEvent, Task}
  alias AshEnterprise.Decisions
  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.{Lowering, ModelVersion, Run}
  alias AshEnterprise.Platform.SystemActor
  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.{CanonicalJSON, Definition, Input}
  alias AshPlanning.Snapshot, as: PlanningSnapshot

  @decision_key "canonical_planning.requirements"

  @purposes %{"planning.personal_week" => :"planning.personal_week"}
  @roles %{"task" => :task, "calendar_event" => :calendar_event, "pinned_task" => :pinned_task}
  @statuses %{
    "value" => :value,
    "unresolved" => :unresolved,
    "invalid" => :invalid,
    "missing_citation" => :missing_citation
  }
  @worlds %{"operational" => :operational, "scenario" => :scenario}
  @completeness %{
    "authorized_subset" => :authorized_subset,
    "declared_complete" => :declared_complete
  }
  @kinds %{"dmn" => :dmn, "bpmn" => :bpmn, "mzn" => :mzn, "validator" => :validator}

  @doc "The key the shipped requirements decision is published under."
  @spec decision_key() :: String.t()
  def decision_key, do: @decision_key

  @doc """
  Prepares a pending run. See the moduledoc.

  Option `:completeness` is the run's declared *scope* (the envelope's
  `authority.completeness`): `:authorized_subset` (default: the run reads only what
  authorization admits) or `:declared_complete` (an explicit declaration that the input set is
  the complete universe). It never reflects input resolution; that is each input's `status`.
  """
  @spec prepare(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def prepare(run, opts \\ [])

  def prepare(%Run{preparation_status: :pending} = run, opts) do
    cutoff = run.knowledge_cutoff || DateTime.utc_now()
    completeness = Keyword.get(opts, :completeness, :authorized_subset)

    unless completeness in [:authorized_subset, :declared_complete],
      do: raise(ArgumentError, "unknown completeness #{inspect(completeness)}")

    run
    |> build(cutoff, completeness)
    |> record(run, cutoff)
  end

  def prepare(%Run{} = run, _opts), do: {:ok, run}

  @doc """
  The snapshot envelope stored in a prepared run's decoded problem payload, rebuilt as a
  `AshOpenLineage.Snapshot` with its digest *verified* against the canonical encoding.
  """
  @spec snapshot_from_payload(map()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot_from_payload(%{"snapshot" => %{} = map}) do
    with {:ok, snapshot} <- decode_snapshot(map) do
      if PlanningSnapshot.verify(snapshot),
        do: {:ok, snapshot},
        else: {:error, :snapshot_digest_mismatch}
    end
  end

  def snapshot_from_payload(_payload), do: {:error, :no_snapshot}

  @doc "The run's decoded, unsealed problem payload (decimals as `Decimal`)."
  @spec problem_payload(struct()) :: {:ok, map()} | {:error, term()}
  def problem_payload(%Run{} = run) do
    with {:ok, binary} <- unseal(run, :problem_payload, run.organization_id),
         {:ok, %{} = payload} <- Jason.decode(binary, floats: :decimals) do
      {:ok, payload}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :problem_payload_unreadable}
      {:ok, _other} -> {:error, :problem_payload_unreadable}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Opens a sealed attribute of `record`: `{:error, :shredded}` once its scope is gone.
  @spec unseal(struct(), atom(), String.t()) :: {:ok, binary()} | {:error, term()}
  def unseal(record, field, tenant) do
    case Ash.load(record, field, tenant: tenant, authorize?: false) do
      {:ok, loaded} ->
        case Map.get(loaded, field) do
          value when is_binary(value) -> {:ok, value}
          %AshEnterprise.Erasure.Shredded{} -> {:error, :shredded}
          nil -> {:error, :empty}
          _other -> {:error, :unreadable}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # ── build ──────────────────────────────────────────────────────────────────

  defp build(run, cutoff, completeness) do
    stamped = %{run | knowledge_cutoff: cutoff}
    week_start = Lowering.week_start(cutoff)

    with {:ok, binding} <- fetch(Run.resolve_binding(stamped), :binding_unavailable),
         {:ok, purpose} <- purpose(binding),
         {:ok, mv} <-
           fetch(
             Ash.get(ModelVersion, run.model_version_id,
               tenant: run.organization_id,
               authorize?: false
             ),
             :model_version_unavailable
           ),
         {:ok, requirements, decision} <- requirements(run, binding),
         {:ok, reads} <- read_inputs(run, cutoff, week_start, requirements) do
      definitions = definitions(binding, mv, decision)
      assemble(run, cutoff, week_start, purpose, reads, requirements, definitions, completeness)
    else
      {:error, reason} -> {:failed, reason}
    end
  end

  defp assemble(run, cutoff, week_start, purpose, reads, requirements, definitions, completeness) do
    inputs = reads.inputs
    unresolved = Enum.filter(inputs, &(&1.status != :value))
    stats = reads.stats

    base = %Snapshot{
      id: run.id,
      purpose: purpose,
      effective_at: week_start,
      knowledge_cutoff: cutoff,
      world: run.world,
      authority: %{
        tenant: run.organization_id,
        actor_id: run.requested_actor_id,
        completeness: completeness
      },
      inputs: inputs,
      definitions: definitions
    }

    if unresolved == [] do
      lowering = %{
        week_start: week_start,
        cutoff: cutoff,
        tasks: reads.tasks,
        meetings: reads.meetings,
        pins: reads.pins,
        requirements: requirements
      }

      case Lowering.lower(lowering) do
        {:ok, lowered} ->
          snapshot = PlanningSnapshot.seal(%{base | payload_hash: hash(lowered)})
          payload = Map.put(lowered, "snapshot", encode_snapshot(snapshot))
          {:prepared, snapshot, payload, stats}

        {:error, reason} ->
          {:failed, reason}
      end
    else
      {:needs_input, PlanningSnapshot.seal(base), Enum.map(unresolved, &unresolved_entry/1),
       stats}
    end
  end

  defp unresolved_entry(%Input{} = input) do
    %{
      "id" => input.key,
      "resource" => input.source && to_string(input.source.resource),
      "status" => Atom.to_string(input.status),
      "reason" => reason_code(input.status)
    }
  end

  defp reason_code(:unresolved), do: "missing_estimate"
  defp reason_code(:invalid), do: "invalid_estimate"
  defp reason_code(:missing_citation), do: "missing_citation"
  defp reason_code(other), do: Atom.to_string(other)

  # ── record ─────────────────────────────────────────────────────────────────

  defp record({:prepared, snapshot, payload, stats}, run, cutoff) do
    write(run, %{
      preparation_status: :prepared,
      snapshot_digest: snapshot.digest,
      knowledge_cutoff: cutoff,
      problem_payload: Jason.encode!(payload),
      stats: stats
    })
  end

  defp record({:needs_input, snapshot, unresolved, stats}, run, cutoff) do
    write(run, %{
      preparation_status: :needs_input,
      snapshot_digest: snapshot.digest,
      knowledge_cutoff: cutoff,
      unresolved_inputs: unresolved,
      stats: stats
    })
  end

  defp record({:failed, reason}, run, cutoff) do
    write(run, %{
      preparation_status: :preparation_failed,
      knowledge_cutoff: cutoff,
      stats: %{"reason" => reason_string(reason)}
    })
  end

  defp write(run, params) do
    Planning.prepare_planning_run(run, params,
      actor: SystemActor.oban(),
      tenant: run.organization_id
    )
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_other), do: "unknown"

  # ── binding / purpose / definitions ────────────────────────────────────────

  defp fetch({:ok, value}, _reason), do: {:ok, value}
  defp fetch({:error, _}, reason), do: {:error, reason}

  # The binding's selector is the canonical-JSON `{"model_key","purpose"}` string.
  defp purpose(%{selector: selector}) do
    with {:ok, %{"purpose" => purpose}} <- Jason.decode(selector),
         {:ok, atom} <- Map.fetch(@purposes, purpose) do
      {:ok, atom}
    else
      _ -> {:error, :unsupported_purpose}
    end
  end

  defp definitions(binding, mv, decision) do
    selected =
      for entry <- binding.selection || [],
          kind = Map.get(@kinds, to_string(get(entry, :kind))),
          not is_nil(kind) do
        %Definition{
          kind: kind,
          key: to_string(get(entry, :key)),
          version: to_string(get(entry, :version)),
          content_hash: to_string(get(entry, :content_hash))
        }
      end

    pinned = [
      %Definition{
        kind: :dmn,
        key: decision.key,
        version: to_string(decision.version),
        content_hash: decision.content_hash
      },
      %Definition{
        kind: :mzn,
        key: mv.key,
        version: to_string(mv.version),
        content_hash: mv.model_sha256
      },
      %Definition{
        kind: :mzn,
        key: mv.key <> ".checker",
        version: to_string(mv.version),
        content_hash: mv.checker_sha256
      },
      %Definition{
        kind: :validator,
        key: mv.validator_module,
        version: to_string(mv.version),
        content_hash: mv.validator_sha256
      }
    ]

    (selected ++ pinned) |> Enum.uniq_by(&{&1.kind, &1.key, &1.version})
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # Resolves the tenant's decision, refuses drift from what the binding pinned, and
  # evaluates the pinned definition once per weekday.
  defp requirements(run, binding) do
    tenant = run.organization_id

    with {:ok, definition} <-
           fetch(
             AshEnterprise.Process.Resolver.resolve(:decision, @decision_key, tenant),
             :decision_unavailable
           ),
         :ok <- check_pin(binding, definition) do
      Enum.reduce_while(Lowering.weekdays(), {:ok, %{}, definition}, fn weekday, acc ->
        evaluate_weekday(weekday, acc, definition, tenant)
      end)
    end
  end

  defp evaluate_weekday(weekday, {:ok, acc, resolved}, definition, tenant) do
    case Decisions.evaluate(@decision_key, %{"weekday" => weekday},
           tenant: tenant,
           pinned: definition.id
         ) do
      {:ok, %{outputs: outputs}} ->
        {:cont, {:ok, Map.put(acc, weekday, requirement(outputs)), resolved}}

      {:error, _} ->
        {:halt, {:error, :decision_failed}}
    end
  end

  defp check_pin(binding, definition) do
    pinned =
      Enum.find(binding.selection || [], fn entry ->
        to_string(get(entry, :kind)) == "dmn" and to_string(get(entry, :key)) == @decision_key
      end)

    cond do
      is_nil(pinned) ->
        :ok

      to_string(get(pinned, :version)) != to_string(definition.version) ->
        {:error, :definition_drift}

      to_string(get(pinned, :content_hash)) != definition.content_hash ->
        {:error, :definition_drift}

      true ->
        :ok
    end
  end

  # A single-output decision may promote its value or key it by output name.
  defp requirement(%{} = outputs) do
    case Enum.find(Map.values(outputs), &is_map/1) do
      %{} = inner when not is_map_key(outputs, "workStartMinute") -> requirement(inner)
      _ -> Map.new(outputs, fn {key, value} -> {to_string(key), to_int(value)} end)
    end
  end

  defp requirement(_other), do: %{}

  defp to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: round(n)
  defp to_int(other), do: other

  # ── reads ──────────────────────────────────────────────────────────────────

  defp read_inputs(run, cutoff, week_start, requirements) do
    horizon_end = DateTime.add(week_start, 7 * 86_400, :second)
    opts = [tenant: run.organization_id, authorize?: false]
    owner = run.requested_actor_id

    with {:ok, rows} <- read_tasks(owner, opts),
         {:ok, events} <- read_events(owner, week_start, horizon_end, cutoff, opts) do
      {:ok, classify(rows, events, week_start, horizon_end, requirements)}
    else
      {:error, _} -> {:error, :read_failed}
    end
  end

  defp read_tasks(owner, opts) do
    Task
    |> Ash.Query.filter(owner_id == ^owner and owner_type == :user and status == :open)
    |> Ash.Query.select([
      :id,
      :version_number,
      :estimated_minutes,
      :due_at,
      :scheduled_start_at,
      :scheduled_end_at,
      :status
    ])
    |> Ash.read(opts)
  end

  defp read_events(owner, from, until, cutoff, opts) do
    CalendarEvent
    |> Ash.Query.filter(
      owner_id == ^owner and owner_type == :user and status != :cancelled and
        starts_at < ^until and ends_at > ^from
    )
    |> Ash.Query.select([:id, :version_number, :starts_at, :ends_at, :status])
    |> Ash.read(Keyword.put(opts, :as_of, cutoff))
  end

  defp classify(task_rows, events, week_start, horizon_end, requirements) do
    {pinned, free} =
      task_rows
      |> Enum.reject(&scheduled_outside?(&1, week_start, horizon_end))
      |> Enum.split_with(&scheduled?/1)

    {plannable, unresolved} = Enum.split_with(free, &valid_estimate?/1)

    task_inputs =
      Enum.map(plannable, &input(&1, :task, :value, task_hash(&1))) ++
        Enum.map(unresolved, &input(&1, :task, estimate_status(&1), nil))

    pin_inputs = Enum.map(pinned, &input(&1, :pinned_task, :value, task_hash(&1)))
    event_inputs = Enum.map(events, &input(&1, :calendar_event, :value, event_hash(&1)))

    %{
      inputs: task_inputs ++ pin_inputs ++ event_inputs,
      tasks:
        Enum.map(
          plannable,
          &%{id: &1.id, duration_minutes: &1.estimated_minutes, due_at: &1.due_at}
        ),
      pins:
        Enum.map(
          pinned,
          &%{id: &1.id, starts_at: &1.scheduled_start_at, ends_at: &1.scheduled_end_at}
        ),
      meetings:
        Enum.map(events, fn event ->
          confirmed? = event.status == :confirmed

          %{
            id: event.id,
            starts_at: event.starts_at,
            ends_at: event.ends_at,
            # A confirmed event is a work commitment only when it overlaps the
            # working window its weekday gets from the requirements decision.
            # Confirmed events on non-working days (weekends, per the DMN) or
            # wholly outside the window never bind the schedule — a hard
            # mandatory there made every real-calendar week UNSAT (all-day
            # weekend double-bookings).
            mandatory?: confirmed? and working_event?(event, requirements),
            priority: if(confirmed?, do: 3, else: 1)
          }
        end),
      stats: %{
        "tasks" => length(plannable),
        "unresolved" => length(unresolved),
        "pinned" => length(pinned),
        "meetings" => length(events)
      }
    }
  end

  defp scheduled?(%{scheduled_start_at: s, scheduled_end_at: e}),
    do: not is_nil(s) and not is_nil(e)

  @doc false
  # A confirmed event binds the schedule only when it overlaps the working
  # window its weekday gets from the requirements decision (UTC). Events on
  # non-working days or wholly outside the window never become mandatory.
  def working_event?(%{starts_at: starts_at, ends_at: ends_at}, requirements) do
    weekday = Lowering.weekdays() |> Enum.at(Date.day_of_week(DateTime.to_date(starts_at)) - 1)
    day = Map.get(requirements, weekday) || %{}
    start_minute = day["workStartMinute"]
    end_minute = day["workEndMinute"]

    if is_integer(start_minute) and is_integer(end_minute) and start_minute < end_minute do
      date = DateTime.to_date(starts_at)

      window_start =
        DateTime.new!(date, Time.add(~T[00:00:00], start_minute * 60, :second), "Etc/UTC")

      window_end =
        DateTime.new!(date, Time.add(~T[00:00:00], end_minute * 60, :second), "Etc/UTC")

      DateTime.compare(starts_at, window_end) == :lt and
        DateTime.compare(window_start, ends_at) == :lt
    else
      false
    end
  end

  defp scheduled_outside?(row, from, until) do
    scheduled?(row) and
      (DateTime.compare(row.scheduled_end_at, from) != :gt or
         DateTime.compare(row.scheduled_start_at, until) != :lt)
  end

  defp valid_estimate?(%{estimated_minutes: m}), do: is_integer(m) and m > 0

  defp estimate_status(%{estimated_minutes: nil}), do: :unresolved
  defp estimate_status(_row), do: :invalid

  defp input(row, role, status, content_hash) do
    resource = if role == :calendar_event, do: CalendarEvent, else: Task

    %Input{
      key: row.id,
      role: role,
      status: status,
      source: %{resource: inspect(resource), id: row.id, version_number: row.version_number},
      content_hash: content_hash
    }
  end

  defp task_hash(row) do
    hash(%{
      estimated_minutes: row.estimated_minutes,
      due_at: row.due_at,
      scheduled_start_at: row.scheduled_start_at,
      scheduled_end_at: row.scheduled_end_at,
      status: row.status
    })
  end

  defp event_hash(row),
    do: hash(%{starts_at: row.starts_at, ends_at: row.ends_at, status: row.status})

  defp hash(term),
    do: :crypto.hash(:sha256, CanonicalJSON.encode!(term)) |> Base.encode16(case: :lower)

  # ── envelope <-> JSON ──────────────────────────────────────────────────────

  defp encode_snapshot(%Snapshot{} = s) do
    %{
      "id" => s.id,
      "purpose" => Atom.to_string(s.purpose),
      "effective_at" => DateTime.to_iso8601(s.effective_at),
      "knowledge_cutoff" => DateTime.to_iso8601(s.knowledge_cutoff),
      "world" => Atom.to_string(s.world),
      "authority" => %{
        "tenant" => s.authority.tenant,
        "actor_id" => s.authority.actor_id,
        "completeness" => Atom.to_string(s.authority.completeness)
      },
      "inputs" =>
        Enum.map(s.inputs, fn i ->
          %{
            "key" => i.key,
            "role" => Atom.to_string(i.role),
            "status" => Atom.to_string(i.status),
            "source" =>
              i.source &&
                %{
                  "resource" => to_string(i.source.resource),
                  "id" => i.source.id,
                  "version_number" => i.source.version_number
                },
            "content_hash" => i.content_hash
          }
        end),
      "definitions" =>
        Enum.map(s.definitions, fn d ->
          %{
            "kind" => Atom.to_string(d.kind),
            "key" => d.key,
            "version" => d.version,
            "content_hash" => d.content_hash
          }
        end),
      "payload_hash" => s.payload_hash,
      "digest" => s.digest
    }
  end

  defp decode_snapshot(map) do
    with {:ok, purpose} <- Map.fetch(@purposes, map["purpose"]),
         {:ok, world} <- Map.fetch(@worlds, map["world"]),
         {:ok, completeness} <-
           Map.fetch(@completeness, get_in(map, ["authority", "completeness"])),
         {:ok, effective_at, _} <- DateTime.from_iso8601(map["effective_at"]),
         {:ok, cutoff, _} <- DateTime.from_iso8601(map["knowledge_cutoff"]),
         {:ok, inputs} <- decode_list(map["inputs"], &decode_input/1),
         {:ok, definitions} <- decode_list(map["definitions"], &decode_definition/1) do
      {:ok,
       %Snapshot{
         id: map["id"],
         purpose: purpose,
         effective_at: effective_at,
         knowledge_cutoff: cutoff,
         world: world,
         authority: %{
           tenant: get_in(map, ["authority", "tenant"]),
           actor_id: get_in(map, ["authority", "actor_id"]),
           completeness: completeness
         },
         inputs: inputs,
         definitions: definitions,
         payload_hash: map["payload_hash"],
         digest: map["digest"]
       }}
    else
      _ -> {:error, :snapshot_unreadable}
    end
  end

  defp decode_list(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp decode_list(_other, _fun), do: :error

  defp decode_input(%{} = i) do
    with {:ok, role} <- Map.fetch(@roles, i["role"]),
         {:ok, status} <- Map.fetch(@statuses, i["status"]) do
      source =
        case i["source"] do
          %{"resource" => r, "id" => id, "version_number" => v} ->
            %{resource: r, id: id, version_number: v}

          _ ->
            nil
        end

      {:ok,
       %Input{
         key: i["key"],
         role: role,
         status: status,
         source: source,
         content_hash: i["content_hash"]
       }}
    else
      _ -> :error
    end
  end

  defp decode_input(_), do: :error

  defp decode_definition(%{} = d) do
    case Map.fetch(@kinds, d["kind"]) do
      {:ok, kind} ->
        {:ok,
         %Definition{
           kind: kind,
           key: d["key"],
           version: d["version"],
           content_hash: d["content_hash"]
         }}

      :error ->
        :error
    end
  end

  defp decode_definition(_), do: :error
end

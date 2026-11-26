defmodule AshEnterprise.Documents.Paper.Clauses do
  @moduledoc """
  Selection at issue, between the payload and the render: a document carries
  only the clauses its tenant's binding activated. For each candidate clause
  key of the kind (`Paper.clause_keys/1`) that the binding's selection pins —
  in any locale — the tenant's `paper.clause.<key>` decision table says
  whether the clause is in, and why — in the matched rule's description, the
  author's own words.

  Before anything is decided, the binding's clause pins are checked against
  the tenant's admitted wording for every candidate key, every locale: a
  version admitted or retired since the binding was written makes the binding
  stale (`{:binding_stale, selection}`) until it is rebound — the same refusal
  a theme, schema or layout drift gets.

  Then only the pinned keys are decided (`bound_keys/2`). A binding that pins
  no clause is a decision made at activation: the document carries no clause,
  and no table is consulted, so a tenant that never admitted wording needs no
  `paper.clause.*` table to issue. A key the binding pins is decided, and its
  table is required: a tenant that admits a clause is stale until it rebinds,
  and after the rebinding a missing table is `{:clause_undecided, key}`.

  Per pinned key:

    1. every input the table declares (its DMN `inputData`) must be one
       `Paper.decision_inputs/2` produces, or the issue is refused
       (`{:missing_decision_input, key, input}`);
    2. the decision evaluates through `AshEnterprise.Decisions.evaluate/3` with
       `record: :required` and the run's id as correlation id — an answer
       nobody can audit is not acted on. A failed evaluation, a UNIQUE
       violation among them, is `{:clause_decision_failed, key, reason}`;
    3. no matched rule, nil outputs or a non-boolean `include` is
       `{:clause_undecided, key}` — never silently out;
    4. `include: true` selects the clause, and its reason is the matched rule's
       `description`; a blank one is `{:clause_reason_missing, key}`.
       `include: false` is an explicit exclusion: no wording, no reason, but
       the evaluation still rides the snapshot;
    5. the wording is the binding's pinned admitted version in the payload's
       locale; a pinned key with no variant in that locale is
       `{:clause_not_pinned, key, locale}`. (Draft wording is never pinned, so
       a key with only a draft is not decided at all.)

  The selected clauses are resolved with `AshPaper.Clause.resolve/3`; a hole
  the payload cannot fill is the resolve's own refusal.

  Nothing is dropped silently: every refusal is returned to `issue`, which
  records it on the run as a failed render. What ran is returned for the
  render record: each decision definition (pinned beside the schema and
  theme), each evaluation row (a snapshot input), each reason (the run's
  `clause_reasons`) and each answer (`decisions`: the key, the include and the
  matched rule ids, excluded clauses too — a draft's fingerprint).

  `decisions/5`, `current_definitions/3` and `admitted_pins/2` recompute those
  parts on their own, for `PaperRun.issue_draft`'s freshness check; the first
  two decide over the same binding-scoped keys `select/5` does.
  """

  alias AshEnterprise.Decisions
  alias AshEnterprise.Decisions.Evaluation
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.PaperClause
  alias AshEnterprise.Process.Resolver
  alias AshOpenLineage.Snapshot, as: Value

  @typedoc "What selection hands the render and the render record."
  @type selection :: %{
          reasons: [map()],
          clauses: [AshPaper.Clause.t()],
          resolved: [map()],
          inputs: [Value.Input.t()],
          definitions: [Value.Definition.t()],
          decisions: [map()]
        }

  @empty %{reasons: [], clauses: [], resolved: [], inputs: [], definitions: [], decisions: []}

  @doc "A selection with nothing decided and nothing consulted."
  @spec empty() :: selection()
  def empty, do: @empty

  @doc """
  Selects the kind's clauses for `payload` under `binding`, recording each
  evaluation against `run`: `{:ok, selection}`, or `{:error, block}` (one
  refusal) or `{:error, [block]}` (the resolve's refusals).
  """
  @spec select(String.t(), AshPaper.Payload.t(), struct(), struct(), term()) ::
          {:ok, selection()} | {:error, term()}
  def select(kind, payload, binding, run, tenant) do
    case Paper.clause_keys(kind) do
      [] ->
        {:ok, @empty}

      candidates ->
        admitted = Paper.latest_admitted_clauses(candidates, tenant)

        with :ok <- pins_current(binding, admitted) do
          kind
          |> bound_keys(binding)
          |> select_bound(kind, payload, run, tenant, admitted)
        end
    end
  end

  # No pinned clause: the binding activated none, so nothing is decided and
  # the document carries no clause.
  defp select_bound([], _kind, _payload, _run, _tenant, _admitted), do: {:ok, @empty}

  defp select_bound(keys, kind, payload, run, tenant, admitted) do
    with {:ok, steps} <- decide_all(keys, kind, payload, run, tenant, admitted),
         {:ok, resolved} <- resolve_selected(steps, payload) do
      {:ok,
       %{
         reasons: for(%{reason: reason} <- steps, reason != nil, do: reason),
         clauses: Enum.flat_map(steps, & &1.clause),
         resolved: resolved,
         inputs: Enum.map(steps, & &1.input),
         definitions: Enum.map(steps, & &1.definition),
         decisions: Enum.map(steps, & &1.decision)
       }}
    end
  end

  @doc """
  The kind's candidate clause keys that `binding`'s selection pins, in any
  locale, in candidate order: the keys a document under that binding carries
  a decision for. A clause pin's key is `"<key>/<locale>"`.
  """
  @spec bound_keys(String.t(), struct()) :: [String.t()]
  def bound_keys(kind, binding) do
    pinned = binding |> binding_pins() |> MapSet.new(&pinned_clause_key/1)

    Enum.filter(Paper.clause_keys(kind), &MapSet.member?(pinned, &1))
  end

  defp pinned_clause_key(%{"key" => key}) do
    [clause_key | _locale] = String.split(key, "/", parts: 2)
    clause_key
  end

  @doc """
  Re-evaluates each clause decision `binding` activated for `payload`
  (`bound_keys/2`): one map per bound key with `key`, `include` and
  `rule_ids`, in key order, or the first refusal. `record:` is the
  evaluation's `:record` mode — `:required` (the default) records against
  `run` like the first evaluation; `false` writes nothing, for a read-only
  recompute (`AshEnterprise.Documents.Paper.Fingerprint.moved/4`).
  """
  @spec decisions(String.t(), struct(), AshPaper.Payload.t(), struct(), term(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def decisions(kind, binding, payload, run, tenant, opts \\ []) do
    record = Keyword.get(opts, :record, :required)

    kind
    |> bound_keys(binding)
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, answers} ->
      case answer(key, kind, payload, run, tenant, record) do
        {:ok, _definition, result, include?} ->
          {:cont, {:ok, answers ++ [decision(key, include?, result)]}}

        {:error, _} = blocked ->
          {:halt, blocked}
      end
    end)
  end

  @doc """
  The decision definition each clause key `binding` activated (`bound_keys/2`)
  resolves to now: `key`, `version` and `content_hash`, in key order. A key
  with nothing published reads as nil version and hash, which matches no
  fingerprint.
  """
  @spec current_definitions(String.t(), struct(), term()) :: [map()]
  def current_definitions(kind, binding, tenant) do
    for key <- bound_keys(kind, binding) do
      decision_key = Paper.decision_key(key)

      case Resolver.resolve(:decision, decision_key, tenant) do
        {:ok, definition} ->
          definition_entry(%Value.Definition{
            kind: :dmn,
            key: decision_key,
            version: to_string(definition.version),
            content_hash: definition.content_hash
          })

        {:error, _reason} ->
          %{"key" => decision_key, "version" => nil, "content_hash" => nil}
      end
    end
  end

  @doc "A pinned decision definition as the fingerprint stores it."
  @spec definition_entry(Value.Definition.t()) :: map()
  def definition_entry(%Value.Definition{} = definition) do
    %{
      "key" => definition.key,
      "version" => definition.version,
      "content_hash" => definition.content_hash
    }
  end

  @doc """
  The clause pins the tenant's admitted wording makes now, every locale, sorted:
  the entries a binding written now would store.
  """
  @spec admitted_pins(String.t(), term()) :: [map()]
  def admitted_pins(kind, tenant) do
    case Paper.clause_keys(kind) do
      [] ->
        []

      keys ->
        keys |> Paper.latest_admitted_clauses(tenant) |> Enum.map(&pin_entry/1) |> Enum.sort()
    end
  end

  @doc "The clause pins a binding's selection stores, sorted."
  @spec binding_pins(struct()) :: [map()]
  def binding_pins(binding) do
    binding.selection
    |> Enum.filter(&(&1["kind"] == "clause"))
    |> Enum.map(&Map.take(&1, ["kind", "key", "version", "content_hash"]))
    |> Enum.sort()
  end

  # The binding's clause pins must be exactly the admitted wording now, every
  # locale: a newer admitted version, a retired one or a new locale variant all
  # move what the next run would render, and only a rebinding decides that.
  defp pins_current(binding, admitted) do
    pinned = binding_pins(binding)

    current = admitted |> Enum.map(&pin_entry/1) |> Enum.sort()

    if pinned == current, do: :ok, else: {:error, {:binding_stale, binding.selection}}
  end

  # The entry `AshPaper.Binding.selection/4` stores for one clause.
  defp pin_entry(%PaperClause{} = clause) do
    %{
      "kind" => "clause",
      "key" => "#{clause.key}/#{clause.locale}",
      "version" => to_string(clause.version),
      "content_hash" => clause.content_hash
    }
  end

  defp decide_all(keys, kind, payload, run, tenant, admitted) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, steps} ->
      case decide(key, kind, payload, run, tenant, admitted) do
        {:ok, step} -> {:cont, {:ok, steps ++ [step]}}
        {:error, _} = blocked -> {:halt, blocked}
      end
    end)
  end

  defp decide(key, kind, payload, run, tenant, admitted) do
    decision_key = Paper.decision_key(key)

    with {:ok, definition, result, include?} <- answer(key, kind, payload, run, tenant, :required),
         {:ok, evaluation} <- recorded_evaluation(result, tenant, key) do
      step = %{
        step(decision_key, definition, evaluation)
        | decision: decision(key, include?, result)
      }

      if include? do
        select_clause(step, key, payload.locale, result, admitted)
      else
        # An explicit rule leaves the clause out: no wording and no reason, but
        # the evaluation ran and rides the snapshot as evidence.
        {:ok, step}
      end
    end
  end

  # The decision answered: its definition, its result and whether the clause is
  # in. Every refusal before that is the selection's own.
  defp answer(key, kind, payload, run, tenant, record) do
    inputs = Paper.decision_inputs(kind, payload)

    with {:ok, definition} <- resolve_definition(Paper.decision_key(key), key, tenant),
         {:ok, result} <- evaluate(definition, inputs, key, run, tenant, record),
         {:ok, include?} <- decided(result, key) do
      {:ok, definition, result, include?}
    end
  end

  defp decision(key, include?, result),
    do: %{"key" => key, "include" => include?, "rule_ids" => result.matched_rule_ids}

  defp select_clause(step, key, locale, result, admitted) do
    with {:ok, rule_id, description} <- matched_reason(result, key),
         {:ok, clause} <- pinned_clause(key, locale, admitted) do
      reason = %{
        "key" => key,
        "locale" => to_string(locale),
        "version" => clause.version,
        "content_hash" => clause.content_hash,
        "decision_key" => step.definition.key,
        "decision_version" => result.definition_version,
        "rule_id" => rule_id,
        "reason" => description
      }

      {:ok, %{step | reason: reason, clause: [PaperClause.to_kernel(clause)]}}
    end
  end

  defp step(decision_key, definition, evaluation) do
    %{
      reason: nil,
      clause: [],
      decision: nil,
      input: %Value.Input{
        key: decision_key,
        role: :decision,
        status: :value,
        source: %{
          resource: inspect(Evaluation),
          id: evaluation.id,
          version_number: evaluation.version_number
        },
        content_hash: evaluation_hash(evaluation)
      },
      definition: %Value.Definition{
        kind: :dmn,
        key: decision_key,
        version: to_string(definition.version),
        content_hash: definition.content_hash
      }
    }
  end

  # What the evaluation saw and answered: the hash a later reader checks the
  # row against.
  defp evaluation_hash(evaluation) do
    AshPaper.Canonical.hash(%{
      "definition_id" => evaluation.definition_id,
      "decision_id" => evaluation.decision_id,
      "inputs" => evaluation.inputs,
      "outputs" => evaluation.outputs,
      "matched_rule_ids" => evaluation.matched_rule_ids,
      "hit_policy" => evaluation.hit_policy
    })
  end

  defp resolve_definition(decision_key, key, tenant) do
    case Resolver.resolve(:decision, decision_key, tenant) do
      {:ok, definition} -> {:ok, definition}
      # Nothing published for the key: no rule can answer, so the clause
      # cannot say why it would be there.
      {:error, _reason} -> {:error, {:clause_undecided, key}}
    end
  end

  # (a) Every input the table declares — its DMN `inputData` — must be one the
  # kind produces (`require_inputs: :declared`): a declared input with no value
  # would evaluate as null into every rule, an answer about a value nobody
  # supplied. (b) The governed path: the evaluation is evidence
  # (`record: :required`), correlated with the run that acts on it, and it
  # evaluates exactly the definition resolved above (`pinned:`), so the pinned
  # definition and the rule's words are the version that decided. A read-only
  # recompute passes `record: false` and writes nothing.
  defp evaluate(definition, inputs, key, run, tenant, record) do
    case Decisions.evaluate(definition.key, inputs,
           tenant: tenant,
           pinned: definition.id,
           record: record,
           require_inputs: :declared,
           correlation_id: run.id
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:missing_inputs, _key, [input | _]}} ->
        {:error, {:missing_decision_input, key, input}}

      {:error, reason} ->
        {:error, {:clause_decision_failed, key, reason}}
    end
  end

  # (c) No matched rule, nil outputs or a non-boolean `include` leaves the
  # clause undecided. A single-output table answers with the bare value; a
  # table that answers a context is read by its `include` entry.
  defp decided(result, key) do
    include =
      case result.outputs do
        outputs when is_map(outputs) -> Map.get(outputs, "include", Map.get(outputs, :include))
        value -> value
      end

    cond do
      result.matched_rule_ids == [] -> {:error, {:clause_undecided, key}}
      not is_boolean(include) -> {:error, {:clause_undecided, key}}
      true -> {:ok, include}
    end
  end

  # The evaluation row the decision just wrote under `record: :required`.
  defp recorded_evaluation(%{evaluation_id: id}, tenant, key) when not is_nil(id) do
    case Ash.get(Evaluation, id, tenant: tenant, authorize?: false) do
      {:ok, %Evaluation{} = evaluation} -> {:ok, evaluation}
      other -> {:error, {:clause_decision_failed, key, {:evaluation_not_found, other}}}
    end
  end

  defp recorded_evaluation(_result, _tenant, key),
    do: {:error, {:clause_decision_failed, key, {:evaluation_not_found, nil}}}

  # (d) The reason is the matched rule's description, as the evaluated
  # definition states it. A rule that cannot say why the clause is there does
  # not include it.
  defp matched_reason(%{matched_rules: [%{id: rule_id, description: description}]}, key) do
    if is_binary(description) and String.trim(description) != "" do
      {:ok, rule_id, description}
    else
      {:error, {:clause_reason_missing, key}}
    end
  end

  # More than one matched rule under any policy that still answered: no one
  # rule's words are the reason.
  defp matched_reason(_result, key), do: {:error, {:clause_reason_missing, key}}

  # (e) The binding's pinned admitted version in the payload's locale.
  # `pins_current/2` has already proved the pins are the admitted set.
  defp pinned_clause(key, locale, admitted) do
    case Enum.find(admitted, &(&1.key == key and &1.locale == locale)) do
      nil -> {:error, {:clause_not_pinned, key, locale}}
      clause -> {:ok, clause}
    end
  end

  defp resolve_selected(steps, payload) do
    clauses = Enum.flat_map(steps, & &1.clause)
    AshPaper.Clause.resolve(clauses, Enum.map(clauses, & &1.key), payload)
  end
end

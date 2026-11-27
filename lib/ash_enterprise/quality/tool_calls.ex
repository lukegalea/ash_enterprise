defmodule AshEnterprise.Quality.ToolCalls do
  @moduledoc """
  The pre-flight gate's System One questions as data, and the one path
  that asks them about a tool call (AST-79).

  `assess/2` is what the gate's rung (`AshEnterprise.Quality.ToolCalls.Rung`)
  calls for a call the rules deferred. For each question it

    1. asks the model through the question's generated judge action, which
       records the answer in the judgment ledger (the state the model saw is
       sealed on it): this is the only model call, made by the gate service,
       never inside a read, a calculation or a policy check;
    2. bands the answer through the family's published band table
       (`AshEnterprise.SystemOne.Banding.Step`), which records the banding
       and admits or omits the fact;
    3. reads the band as a reading: `"yes"` for an admitted yes, `"no"` for
       an admitted no, `"unsure"` for anything else (review, omit, no
       published table, a refusal). Unsure is never folded into yes or no.

  It returns the readings as the gate's banding table
  (`priv/decisions/agent_gate.dmn`) reads them, `"destructive"` and
  `"out_of_scope"`, with `certified`: true only when every family's
  published band table has a certification in force no older than the
  family's `max_age_days`, for the instrument that answered (a table
  certified for another model, digest or runtime is not). The gate turns an allow from uncertified tables
  into an ask. A judge that fails is an error, never a reading: the gate
  answers ask.
  """

  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Quality.Gate
  alias AshEnterprise.Quality.Projections.ToolCall, as: Projection
  alias AshEnterprise.Quality.ToolCall
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshJudgments.Registry.Info

  @questions [
    %{
      name: :tool_call_is_destructive,
      action: :judge_tool_call_is_destructive,
      family: :agent_gate_destructive,
      reading: "destructive"
    },
    %{
      name: :tool_call_acts_outside_scope,
      action: :judge_tool_call_acts_outside_scope,
      family: :agent_gate_scope,
      reading: "out_of_scope"
    }
  ]

  @subject_type "AshEnterprise.Quality.ToolCall"

  @doc """
  The questions, in order: `name`, its generated judge `action`, `family` and
  the `reading` key the gate's table reads.
  """
  @spec questions() :: [map()]
  def questions, do: @questions

  @doc "The families, one per question."
  @spec families() :: [atom()]
  def families, do: Enum.map(@questions, & &1.family)

  @doc "The declared registry question for a name: its `question_id`, hash, family and type."
  @spec declared(atom()) :: struct()
  def declared(name), do: Info.question(ToolCall, name)

  @doc """
  The tool call a gate request is about, as a subject: the request's tool,
  command, the paths as the gate's rules see them (relative to their
  repository) and the repository's kind. Takes the gate's request contract
  (atom keys) or the same fields with string keys.
  """
  @spec subject(map()) :: %{id: String.t(), tool: String.t(), command: String.t() | nil}
  def subject(request) do
    call = %{
      tool: get(request, :tool) || "",
      command: get(request, :command),
      paths: paths(request),
      repo_kind: repo_kind(request)
    }

    Map.put(call, :id, "tool_call:" <> digest(call))
  end

  @doc "The subject term facts and bandings are keyed by."
  @spec subject_term(map()) :: %{String.t() => String.t()}
  def subject_term(call), do: %{"type" => @subject_type, "id" => call.id}

  @doc "The sha256 of the state the model sees for a call."
  @spec digest(map()) :: String.t()
  def digest(call) do
    state = call |> Projection.state() |> Jason.encode!()
    Base.encode16(:crypto.hash(:sha256, state), case: :lower)
  end

  @doc """
  Asks every question about `call` and bands each answer (see the
  moduledoc). Returns `{:ok, %{inputs:, certified:, audit:}}`, the shape
  the gate's rung contract takes, or `{:error, {:judge_failed, name}}`
  when a judge fails.

  Options: `:tenant` (required), `:instrument` (required: `model_version`,
  `model_digest`, `runtime_version`), `:actor` (default the `oban` system
  actor), `:judgments` (extra judge-context entries, such as a test's
  `:req_llm`), `:resolver` (the banding step's band-table seam),
  `:band_tables` (`%{family => published_band_table}`, read with
  `AshEnterprise.Quality.Gate.published_band_table/3` by default), `:now`.
  """
  @spec assess(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def assess(call, opts) do
    correlation_id = Keyword.get(opts, :correlation_id) || Correlation.id()
    opts = Keyword.put(opts, :correlation_id, correlation_id)
    tables = band_tables(opts)

    @questions
    |> Task.async_stream(&ask(&1, call, opts), timeout: :infinity, ordered: true)
    |> Enum.map(fn {:ok, result} -> result end)
    |> collect(tables, opts)
  end

  @doc """
  Asks one question about `call` through its judge action and records the
  answer. Returns `{:ok, answer, observation_id}` or `{:error, error}`.
  Takes `assess/2`'s options, `:mode` (`:live` by default) and `:purpose`,
  recorded in the row's `state_ref` (`"gate"` by default; a calibration pass
  records `"calibration"`).
  """
  @spec judge(atom(), map(), keyword()) :: {:ok, map(), Ash.UUID.t()} | {:error, term()}
  def judge(name, call, opts) do
    question = declared(name)
    observation_id = Ash.UUID.generate()
    actor = Keyword.get(opts, :actor, SystemActor.oban())
    input = judge_input(name, call, actor: actor)

    context =
      SystemOne.judge_context(
        tenant: Keyword.fetch!(opts, :tenant),
        correlation_id: Keyword.get(opts, :correlation_id),
        judgments:
          Map.merge(
            %{
              req_llm: SystemOne.DecisionWire,
              instrument: instrument!(opts),
              subject: %{type: @subject_type, id: call.id},
              observation_id: observation_id,
              mode: Keyword.get(opts, :mode, :live),
              state_ref: %{"purpose" => Keyword.get(opts, :purpose, "gate")}
            },
            Keyword.get(opts, :judgments, %{})
          ),
        judged_state: SystemOne.JudgedState.project(question, input)
      )

    case Ash.run_action(input, context: context) do
      {:ok, answer} -> {:ok, answer, observation_id}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The judge action's input for one question about one call."
  @spec judge_input(atom(), map(), keyword()) :: Ash.ActionInput.t()
  def judge_input(name, call, opts \\ []) do
    %{action: action} = Enum.find(@questions, &(&1.name == name))

    Ash.ActionInput.for_action(
      ToolCall,
      action,
      %{"input" => Projection.state(call)},
      opts
    )
  end

  @doc """
  A banding step's result as a reading: `"yes"` or `"no"` for an admitted
  answer, `"unsure"` for everything else.
  """
  @spec reading(term()) :: String.t()
  defdelegate reading(result), to: Step

  ## Asking one question

  defp ask(question, call, opts) do
    case judge(question.name, call, opts) do
      {:ok, answer, observation_id} ->
        banded = band(question, answer, observation_id, call, opts)
        {:ok, question, answer, observation_id, banded}

      {:error, _error} ->
        {:error, {:judge_failed, question.name}}
    end
  end

  defp band(question, answer, observation_id, call, opts) do
    declared = declared(question.name)

    Step.band(
      [%{question: declared, answer: answer, observation_id: observation_id}],
      [
        family: to_string(question.family),
        tenant: Keyword.fetch!(opts, :tenant),
        subject: subject_term(call),
        predicate: declared.question_id,
        subject_state_digest: digest(call),
        holds_value: true,
        correlation_id: Keyword.get(opts, :correlation_id),
        mode: Keyword.get(opts, :mode, :live)
      ] ++ Keyword.take(opts, [:resolver])
    )
  end

  defp collect(results, tables, opts) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        answered =
          for {:ok, question, answer, id, banded} <- results, do: {question, answer, id, banded}

        {:ok,
         %{
           inputs: Map.new(answered, fn {q, _a, _id, banded} -> {q.reading, reading(banded)} end),
           certified: Enum.all?(families(), &Gate.certified?(Map.get(tables, &1), &1, opts)),
           audit: audit(answered, tables, opts)
         }}
    end
  end

  defp audit(answered, tables, opts) do
    instrument = instrument!(opts)

    %{
      model_version: instrument.model_version,
      model_digest: instrument.model_digest,
      runtime_version: instrument.runtime_version,
      questions:
        Enum.map(answered, fn {question, answer, observation_id, banded} ->
          declared = declared(question.name)

          %{
            question: question.name,
            family: question.family,
            question_hash: declared.question_hash,
            observation_id: observation_id,
            p_true: Map.get(answer, :probability),
            reading: reading(banded),
            band: band_audit(banded),
            band_table: table_audit(Map.get(tables, question.family))
          }
        end)
    }
  end

  defp band_audit({:ok, %{band: band, banding: banding}}),
    do: %{band: band, banding_id: banding.id, band_table: banding.band_table}

  defp band_audit({:refusal, %{reason: reason}}), do: %{refusal: inspect(reason)}
  defp band_audit({:error, error}), do: %{error: error |> error_class()}
  defp band_audit(_other), do: %{error: "unexpected"}

  defp table_audit(nil), do: nil

  defp table_audit(table) do
    %{
      definition_key: table.definition_key,
      definition_version: table.definition_version,
      content_hash: table.content_hash,
      certification: Map.get(table.certification || %{}, :status)
    }
  end

  defp error_class(%module{}), do: inspect(module)
  defp error_class(other) when is_binary(other), do: other
  defp error_class(_other), do: "error"

  ## Certification

  defp band_tables(opts) do
    Keyword.get_lazy(opts, :band_tables, fn ->
      Map.new(families(), fn family ->
        {family, Gate.published_band_table(family, Keyword.fetch!(opts, :tenant), opts)}
      end)
    end)
  end

  ## The request

  defp instrument!(opts) do
    case Keyword.fetch!(opts, :instrument) do
      %{model_version: v, model_digest: d, runtime_version: r} = instrument
      when is_binary(v) and is_binary(d) and is_binary(r) ->
        Map.take(instrument, [:model_version, :model_digest, :runtime_version])

      other ->
        raise ArgumentError, "a tool-call judgment needs an instrument, got #{inspect(other)}"
    end
  end

  defp get(request, key), do: Map.get(request, key, Map.get(request, Atom.to_string(key)))

  # The paths as the rules see them (each relative to its repository), when
  # the gate normalised them; otherwise the paths as given.
  defp paths(request) do
    case get(request, :targets) do
      [_ | _] = targets -> Enum.map(targets, &(get(&1, :path) || ""))
      _none -> List.wrap(get(request, :paths))
    end
  end

  defp repo_kind(request) do
    case get(request, :repo) do
      %{} = repo -> get(repo, :kind)
      _none -> get(request, :repo_kind)
    end
  end
end

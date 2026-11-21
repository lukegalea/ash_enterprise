defmodule AshEnterprise.Quality.Evaluation do
  @moduledoc """
  The evaluation tenant, and the grading of the suite runs that finish in it.

  A suite run started with `start` answers each case with an agent run, and its answer is
  a reply subject (`AshEnterprise.Quality.AgentReply`'s `:from_run`). Those answers are
  graded only in **the** evaluation tenant: a synthetic tenant, so no real person's text
  goes to the judge model (ADR 0058; S1-79, decision 6). Everywhere else nothing is
  graded, and the judged scores read unknown with a reason that says so.

  ## The designation

      config :ash_enterprise, AshEnterprise.Quality.Evaluation,
        tenant: "synthetic-evaluation"

  `:tenant` is the `unique_name` of one organization, as
  `AshEnterprise.Standards.StandingWorker` names its tenant. One name designates one
  tenant, so at most one is ever graded in. Unset (the default), or set to anything but
  a name, nothing is graded anywhere (`:no_evaluation_tenant`); a name no organization
  has grades nowhere either, and says so in the log. `config/runtime.exs` sets it from
  `QUALITY_EVALUATION_TENANT`.

  ## What happens when a suite run finishes

  Only for a suite that names the `agent_reply_style` judged scorer
  (`AshEnterprise.Quality.Changes.Finish`):

    * **In the evaluation tenant.** `finish` reports what the admitted facts say now,
      with `"grading" => %{"status" => "pending"}`, and enqueues
      `AshEnterprise.Quality.SuiteRun.GradeWorker` in its transaction. The worker grades
      each answer through `AshEnterprise.Quality.Grader` (judge, band, admit, with the
      instrument identity below), then `record_judged` recomputes the scores from the
      facts. A model error admits nothing, so that pair stays unknown.
    * **In any other tenant.** Nothing is graded and no fact is read: every score is
      unknown with the reason `not_evaluation_tenant` (or `no_evaluation_tenant` when
      none is designated), and the report is `unmeasured` for it, with
      `"grading" => %{"status" => "not_graded", "reason" => ...}`.

  Grading reports and never gates: `AshEnterprise.Quality.SuiteGate` and the release
  gate read only the deterministic results (ADR 0058, decision D9).

  ## The instrument identity

  Every judgment records the instrument that answered it. By default it is read once per
  grading job from the profile the `agent_reply_style` questions declare
  (`AshEnterprise.SystemOne.Instrument.identity/1`); a job that cannot read it judges
  nothing. `:instrument` replaces the lookup with a map, or a zero-arity function
  returning `{:ok, map}`. `:grader_opts` are further options for `Grader.grade/2` (a test
  transport, a resolver).
  """

  require Logger

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Gate, JudgedScores, Questions, Suite, SuiteRun}
  alias AshEnterprise.SystemOne.Instrument

  @family :agent_reply_style
  @epoch 1

  @typedoc "Why a tenant's answers are not graded."
  @type not_graded :: :no_evaluation_tenant | :not_evaluation_tenant

  @doc "The configuration (see the moduledoc)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:ash_enterprise, __MODULE__, [])

  @doc """
  The evaluation tenant's organization id, or `{:error, :no_evaluation_tenant}` when none
  is designated or the designation names no organization.
  """
  @spec tenant() :: {:ok, Ash.UUID.t()} | {:error, :no_evaluation_tenant}
  def tenant do
    case config()[:tenant] do
      name when is_binary(name) and name != "" -> organization(name)
      _unset -> {:error, :no_evaluation_tenant}
    end
  end

  defp organization(name) do
    case Organization.by_unique_name(name, actor: SystemActor.oban()) do
      {:ok, %{id: id}} ->
        {:ok, id}

      _none ->
        Logger.warning("the evaluation tenant #{inspect(name)} names no organization: no grading")
        {:error, :no_evaluation_tenant}
    end
  end

  @doc "Whether `tenant` is the evaluation tenant, or why its answers are not graded."
  @spec designation(Ash.UUID.t() | nil) :: :evaluation_tenant | {:not_graded, not_graded()}
  def designation(tenant) do
    case tenant() do
      {:ok, ^tenant} when is_binary(tenant) -> :evaluation_tenant
      {:ok, _other} -> {:not_graded, :not_evaluation_tenant}
      {:error, reason} -> {:not_graded, reason}
    end
  end

  @doc "Whether `suite` names the judged scorer whose answers are graded."
  @spec judged?(map()) :: boolean()
  def judged?(%{scorers: scorers}),
    do: Enum.any?(scorers, &(&1["kind"] == "judged" and &1["family"] == to_string(@family)))

  @doc """
  Each of `suite`'s cases' answers in `suite_run` as a reply subject
  `"agent_reply:<suite run id>/<case id>/1"`, read as the `oban` system actor, in case
  order. A case with no text answer is a stand-in with no text and no facts, which reads
  unknown. `runs` maps case ids to their agent runs; read here when not given.
  """
  @spec replies(map(), map(), map() | nil, Ash.UUID.t()) :: [map()]
  def replies(suite_run, suite, runs \\ nil, tenant) do
    runs = runs || runs(suite_run, suite, tenant)
    opts = [tenant: tenant, actor: SystemActor.oban()]
    Enum.map(suite.cases, &reply(suite_run, &1[:id], Map.get(runs, &1[:id]), opts))
  end

  @doc "The suite of `suite_run`, read as the job runner."
  @spec suite(map(), Ash.UUID.t()) :: map()
  def suite(suite_run, tenant),
    do: Ash.get!(Suite, suite_run.suite_id, authorize?: false, tenant: tenant)

  defp runs(suite_run, suite, tenant) do
    keys = Map.new(suite.cases, &{SuiteRun.run_key(suite_run.id, &1[:id], @epoch), &1[:id]})

    Execution.list_agent_runs!(
      query: [filter: [run_key: [in: Map.keys(keys)]]],
      authorize?: false,
      tenant: tenant
    )
    |> Map.new(&{Map.fetch!(keys, &1.run_key), &1})
  end

  defp reply(suite_run, case_id, run, opts) do
    args = %{run_id: suite_run.id, case_id: case_id, epoch: @epoch}

    case run && Quality.reply_from_run(run.id, args, opts) do
      {:ok, %Quality.AgentReply{} = reply} ->
        reply

      _no_answer ->
        %{id: "agent_reply:#{suite_run.id}/#{case_id}/#{@epoch}", text: "", used_tools: false}
    end
  end

  @doc """
  The judged scores of `replies` and the report, with `grading` put in it as
  `"grading"`: read from the admitted facts, or, when `grading` says the replies are not
  graded, unknown for that reason without reading a fact. Calls no model.
  """
  @spec scores([map()], map(), Ash.UUID.t()) :: %{scores: map(), report: map()}
  def scores(replies, grading, tenant) do
    opts = [tenant: tenant, actor: SystemActor.oban()] ++ not_graded(grading)
    report = Gate.family_report(replies, @family, opts)
    JudgedScores.build(replies, report, [grading: grading] ++ opts)
  end

  @not_graded %{
    "no_evaluation_tenant" => :no_evaluation_tenant,
    "not_evaluation_tenant" => :not_evaluation_tenant
  }

  defp not_graded(%{"status" => "not_graded", "reason" => reason}),
    do: [not_graded: Map.fetch!(@not_graded, reason)]

  defp not_graded(_graded_or_pending), do: []

  @doc "The `\"grading\"` entry of a report whose replies are not graded, for `reason`."
  @spec not_graded_entry(not_graded()) :: map()
  def not_graded_entry(reason), do: %{"status" => "not_graded", "reason" => to_string(reason)}

  @doc """
  The instrument identity each judgment records (see the moduledoc): `{:ok, map}` or
  `{:error, reason}`.
  """
  @spec instrument() :: {:ok, map()} | {:error, term()}
  def instrument do
    case Keyword.get(config(), :instrument, &default_instrument/0) do
      %{} = instrument -> {:ok, instrument}
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp default_instrument do
    case Questions.names() |> Enum.map(&Questions.declared(&1).profile) |> Enum.uniq() do
      [profile] -> Instrument.identity(profile)
      profiles -> {:error, {:not_one_profile, profiles}}
    end
  end

  @doc "Further options for `AshEnterprise.Quality.Grader.grade/2` (see the moduledoc)."
  @spec grader_opts() :: keyword()
  def grader_opts, do: Keyword.get(config(), :grader_opts, [])
end

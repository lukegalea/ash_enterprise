defmodule AshEnterprise.Test.Quality.SuiteRuns do
  @moduledoc """
  Suite runs of `AshEnterprise.Test.Quality.ReferralReplier`, an agent that answers in
  words, so each case's answer is a reply subject the `agent_reply_style` questions read;
  and the evaluation tenant's designation (`AshEnterprise.Quality.Evaluation`), set for
  one test and restored after it. Every name and sentence is synthetic.

  Uses `AshEnterprise.Test.Execution.Runs`: call its `in_zone!/0`, `pause_queues!/0` and
  `published!/3` (with `ReferralReplier`) first.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  import AshEnterprise.Test.Execution.Runs,
    only: [script!: 1, step!: 1, run: 1, oban: 1]

  alias AshEnterprise.Execution
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Evaluation

  @agent "clinic.referral_replier"
  @answer "SYNTHETIC: the referral for patient 7 will be sent on 2026-12-01."

  @doc "The replying agent's key."
  def agent, do: @agent

  @doc "The answer every case's run gives."
  def answer, do: @answer

  @doc """
  Publishes the suite `key` in `clinic`: one case per id in `case_ids`, each with a
  deterministic `max_steps` assertion, naming the `agent_reply_style` judged scorer.
  """
  def suite!(clinic, key, case_ids) do
    cases =
      for id <- case_ids do
        %{
          id: id,
          input: "SYNTHETIC: when will patient 7's referral be sent?",
          assertions: [%{type: :max_steps, limit: 4}]
        }
      end

    opts = [actor: clinic.admin.actor, tenant: clinic.tenant]

    key
    |> Quality.create_suite_draft!(
      %{cases: cases, scorers: [%{"kind" => "judged", "family" => "agent_reply_style"}]},
      opts
    )
    |> Quality.publish_suite!(opts)
  end

  @doc """
  Starts `suite` as the administrator (`attrs` go to `start`, such as
  `release_manifest_id`) and drives each case's run to its answer. Not finished yet.
  """
  def started!(clinic, suite, attrs \\ %{}) do
    suite_run =
      Quality.start_suite_run!(suite.id, @agent, attrs,
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    for %{id: case_id} <- suite.cases do
      script!([{:text, @answer}])
      assert drive!(case_run(clinic, suite_run, case_id)).status == :completed
    end

    suite_run
  end

  @doc "Runs the `finish` trigger and returns the finished suite run."
  def finished!(clinic, suite_run) do
    AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
    Quality.get_suite_run!(suite_run.id, oban(clinic.tenant))
  end

  @doc "The agent run that answered `case_id` in `suite_run`."
  def case_run(clinic, suite_run, case_id) do
    [run] =
      Execution.list_agent_runs!(
        query: [filter: [run_key: Quality.SuiteRun.run_key(suite_run.id, case_id, 1)]],
        authorize?: false,
        tenant: clinic.tenant
      )

    run
  end

  @doc "`suite_run`'s case results, by case id."
  def case_results(clinic, suite_run) do
    [query: [filter: [suite_run_id: suite_run.id]], authorize?: false, tenant: clinic.tenant]
    |> Quality.list_case_results!()
    |> Map.new(&{&1.case_id, &1})
  end

  @doc """
  Sets `AshEnterprise.Quality.Evaluation`'s configuration for this test: `tenant` is the
  designated organization's `unique_name` (nil designates none), `extra` the other keys.
  Restored on exit.
  """
  def designate!(tenant, extra \\ []) do
    previous = Application.get_env(:ash_enterprise, Evaluation)
    Application.put_env(:ash_enterprise, Evaluation, [tenant: tenant] ++ extra)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, Evaluation, previous),
        else: Application.delete_env(:ash_enterprise, Evaluation)
    end)
  end

  defp drive!(run) do
    Enum.reduce_while(1..4, run, fn _round, run ->
      step!(run)
      Oban.drain_queue(queue: :execution)
      run = run(run)
      if run.status in [:completed, :failed, :cancelled], do: {:halt, run}, else: {:cont, run}
    end)
  end
end

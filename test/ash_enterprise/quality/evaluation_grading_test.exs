defmodule AshEnterprise.Quality.EvaluationGradingTest do
  @moduledoc """
  S1-97: a `start` suite run's answers are graded only in the designated evaluation
  tenant (`AshEnterprise.Quality.Evaluation`; S1-79, decision 6).

  The judge path is the real one (generated judge action, host judge context, ledger,
  banding step, facts materialiser) with the model replaced through the grader's
  `:judgments` seam (`FakeReqLLM`, or `FailingReqLLM` for a runtime that is down) and the
  band table by a resolver that admits. No model is called. Every tenant, name and
  sentence is synthetic.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.Execution.Runs, except: [agent: 0]
  import AshEnterprise.Test.Quality.SuiteRuns

  require Ash.Query

  alias AshEnterprise.Execution.Release.Gate, as: ReleaseGate
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{SuiteGate, SuiteRun.GradeWorker}
  alias AshEnterprise.SystemOne.Judgment
  alias AshEnterprise.SystemOne.TestSupport.{FailingReqLLM, FakeReqLLM}
  alias AshEnterprise.Test.AssistantFixtures
  alias AshEnterprise.Test.Execution.{Authority, NoNetwork, Releases}
  alias AshEnterprise.Test.Quality.ReferralReplier

  @instrument %{
    model_version: "winnow:12b",
    model_digest: "sha256:" <> String.duplicate("a", 64),
    runtime_version: "synthetic-runtime-1"
  }

  @cases ["first-answer", "second-answer"]

  setup do
    in_zone!()
    pause_queues!()
    :ok = NoNetwork.block!()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    clinic = clinic!()
    Authority.start_grant!(clinic.admin, clinic.admin, agent())
    published!(clinic, %{}, ReferralReplier)
    %{clinic: clinic, suite: suite!(clinic, "clinic.replies", @cases)}
  end

  @doc false
  def admit_table(_family, _tenant, _inputs) do
    {:ok,
     %{
       band_table: %{
         "definition_key" => "judgments_band_agent_reply_style",
         "definition_version" => "1",
         "content_hash" => "sha256:" <> String.duplicate("c", 64),
         "definition_id" => Ash.UUID.generate(),
         "tenant_fork" => nil
       },
       outputs: %{"band" => "admit", "fact_value" => true},
       matched_rule_ids: ["rule_1"],
       decision_evaluation_id: Ash.UUID.generate()
     }}
  end

  defp grading(transport),
    do: [
      instrument: @instrument,
      grader_opts: [judgments: %{req_llm: transport}, resolver: &__MODULE__.admit_table/3]
    ]

  defp designate_clinic!(clinic, transport \\ FakeReqLLM),
    do: designate!(clinic.admin.organization.unique_name, grading(transport))

  defp grade!(suite_run) do
    [job] = all_enqueued(worker: GradeWorker)
    assert job.args == %{"suite_run_id" => suite_run.id, "tenant" => suite_run.organization_id}
    perform_job(GradeWorker, job.args)
  end

  defp judgments(clinic) do
    Judgment
    |> Ash.Query.filter(subject_type == ^Quality.subject_type())
    |> Ash.read!(tenant: clinic.tenant, authorize?: false)
  end

  defp statuses(clinic, suite_run) do
    for {_case_id, result} <- case_results(clinic, suite_run), score <- result.scores do
      {score["status"], score["unknown_reason"]}
    end
  end

  describe "in the evaluation tenant" do
    test "a finished run is graded by its job, and its scores read what was admitted",
         %{clinic: clinic, suite: suite} do
      designate_clinic!(clinic)
      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))

      # Finish asks no model: the scores read what the facts say now, and grading waits.
      assert FakeReqLLM.calls() == 0
      assert suite_run.summary["judged"]["grading"] == %{"status" => "pending"}
      assert Enum.all?(statuses(clinic, suite_run), &(&1 == {"unknown", "no_fact"}))

      assert :ok = grade!(suite_run)

      # The answers used no tool, so all eight questions are asked of each.
      asked = 8 * length(@cases)
      assert FakeReqLLM.calls() == asked
      assert length(judgments(clinic)) == asked

      graded = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant))
      judged = graded.summary["judged"]

      assert judged["grading"] == %{"status" => "graded", "judged" => asked, "judge_errors" => 0}
      assert judged["replies"]["unknown"] == 0
      assert judged["gates"] == false

      # Every case's score is decided now, from a judgment of its answer.
      for {_case_id, result} <- case_results(clinic, suite_run), score <- result.scores do
        assert score["status"] in ["compliant", "violating"]
        assert [_judgment] = score["judgment_ids"]
      end

      # The deterministic results are what finish recorded.
      assert graded.summary["quality"] == suite_run.summary["quality"]
      assert graded.summary["safety"] == suite_run.summary["safety"]
    end

    test "running the job again records no second judgment", %{clinic: clinic, suite: suite} do
      designate_clinic!(clinic)
      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))

      [job] = all_enqueued(worker: GradeWorker)
      assert :ok = perform_job(GradeWorker, job.args)
      calls = FakeReqLLM.calls()
      recorded = judgments(clinic) |> Enum.map(& &1.id) |> Enum.sort()
      first = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant)).summary["judged"]

      assert :ok = perform_job(GradeWorker, job.args)

      assert FakeReqLLM.calls() == calls
      assert judgments(clinic) |> Enum.map(& &1.id) |> Enum.sort() == recorded
      again = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant)).summary["judged"]
      assert again["grading"]["judged"] == 0
      assert Map.delete(again, "grading") == Map.delete(first, "grading")
    end

    test "a model error leaves the scores unknown, never compliant, and the job retries",
         %{clinic: clinic, suite: suite} do
      designate_clinic!(clinic, FailingReqLLM)
      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))

      assert {:error, _reason} = grade!(suite_run)
      assert FailingReqLLM.calls() == 8 * length(@cases)
      assert judgments(clinic) == []

      judged = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant)).summary["judged"]
      assert judged["grading"]["judge_errors"] == 8 * length(@cases)
      assert judged["replies"] == %{"compliant" => 0, "violating" => 0, "unknown" => 2}
      assert judged["verdict"] == "unmeasured"

      assert Enum.all?(statuses(clinic, suite_run), &(&1 == {"unknown", "no_fact"}))
    end

    test "an instrument that cannot be identified judges nothing", %{clinic: clinic, suite: suite} do
      designate!(clinic.admin.organization.unique_name,
        instrument: fn -> {:error, :unreachable} end,
        grader_opts: [judgments: %{req_llm: FakeReqLLM}]
      )

      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))

      assert {:error, :instrument_unavailable} = grade!(suite_run)
      assert FakeReqLLM.calls() == 0
      assert judgments(clinic) == []

      judged = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant)).summary["judged"]
      assert judged["grading"] == %{"status" => "failed", "reason" => "instrument_unavailable"}
    end

    test "grading never changes the deterministic gate or the release gate",
         %{clinic: clinic, suite: suite} do
      designate_clinic!(clinic)

      manifest =
        Releases.resolved!(clinic, "clinic.replies", [
          %{kind: "agent", key: agent()},
          %{kind: "suite", key: "clinic.replies"}
        ])

      suite_run =
        clinic
        |> started!(suite, %{release_manifest_id: manifest.id})
        |> then(&finished!(clinic, &1))

      before = ReleaseGate.check(manifest, clinic.tenant)

      suite_before =
        SuiteGate.result(suite, suite_run, Map.values(case_results(clinic, suite_run)))

      assert :ok = grade!(suite_run)
      graded = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant))

      after_grading = ReleaseGate.check(manifest, clinic.tenant)
      suite_after = SuiteGate.result(suite, graded, Map.values(case_results(clinic, graded)))

      # The judged report moved from pending to graded; nothing else did.
      [entry_before] = before["suites"]
      [entry_after] = after_grading["suites"]
      assert entry_before["judged"]["grading"]["status"] == "pending"
      assert entry_after["judged"]["grading"]["status"] == "graded"

      # Everything but the report and the time of the check.
      drop = fn result ->
        result
        |> Map.delete("checked_at")
        |> Map.update!("suites", &Enum.map(&1, fn entry -> Map.delete(entry, "judged") end))
      end

      assert drop.(after_grading) == drop.(before)
      assert after_grading["passed"] == before["passed"]
      assert suite_after == suite_before

      assert {:ok, _asked} = Releases.request(clinic, manifest)
      assert Releases.reload(clinic, manifest).gate_result["passed"] == before["passed"]
    end
  end

  describe "outside the evaluation tenant" do
    test "a run in another tenant is not graded and reads unknown, not the evaluation tenant",
         %{clinic: clinic, suite: suite} do
      evaluation = AssistantFixtures.tenant!()
      designate!(evaluation.organization.unique_name, grading(FakeReqLLM))

      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))

      assert all_enqueued(worker: GradeWorker) == []
      assert FakeReqLLM.calls() == 0
      assert judgments(clinic) == []

      judged = suite_run.summary["judged"]

      assert judged["grading"] == %{"status" => "not_graded", "reason" => "not_evaluation_tenant"}
      assert judged["verdict"] == "unmeasured"
      assert judged["verdict_reasons"] == ["not_evaluation_tenant"]
      assert judged["replies"] == %{"compliant" => 0, "violating" => 0, "unknown" => 2}

      assert [_ | _] = statuses = statuses(clinic, suite_run)
      assert Enum.all?(statuses, &(&1 == {"unknown", "not_evaluation_tenant"}))
    end

    test "with no evaluation tenant designated, nothing is graded anywhere",
         %{clinic: clinic, suite: suite} do
      designate!(nil, grading(FakeReqLLM))

      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))

      assert all_enqueued(worker: GradeWorker) == []
      assert FakeReqLLM.calls() == 0
      assert judgments(clinic) == []

      assert suite_run.summary["judged"]["grading"] ==
               %{"status" => "not_graded", "reason" => "no_evaluation_tenant"}

      assert Enum.all?(statuses(clinic, suite_run), &(&1 == {"unknown", "no_evaluation_tenant"}))
    end

    test "a job for a tenant that is no longer the evaluation tenant grades nothing",
         %{clinic: clinic, suite: suite} do
      designate_clinic!(clinic)
      suite_run = clinic |> started!(suite) |> then(&finished!(clinic, &1))
      [job] = all_enqueued(worker: GradeWorker)

      designate!(nil, grading(FakeReqLLM))

      assert {:cancel, :no_evaluation_tenant} = perform_job(GradeWorker, job.args)
      assert FakeReqLLM.calls() == 0

      judged = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant)).summary["judged"]
      assert judged["grading"]["reason"] == "no_evaluation_tenant"
      assert Enum.all?(statuses(clinic, suite_run), &(&1 == {"unknown", "no_evaluation_tenant"}))
    end
  end
end

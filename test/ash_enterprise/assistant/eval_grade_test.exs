defmodule AshEnterprise.Assistant.EvalGradeTest do
  @moduledoc """
  S1-95: the eval set's answers graded against the `agent_reply_style`
  family, and the family's gate report printed beside the scorecard, as
  `mix ash_enterprise.assistant.eval` does with a judge instrument.

  The answers come from the scripted oracle (no assistant model). The
  judge path is the real one with the model replaced by `FakeReqLLM` (or
  `FailingReqLLM`) and the band table by a stub resolver, as the grader's
  own tests do. A certified, published table is supplied as the report's
  `:band_table`. Everything here is synthetic.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Quality
  alias AshEnterprise.SystemOne.{Fact, Judgment}
  alias AshEnterprise.SystemOne.TestSupport.{FailingReqLLM, FakeReqLLM}
  alias AshEnterprise.Test.AssistantEval, as: Eval
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias Mix.Tasks.AshEnterprise.Assistant.Eval, as: EvalTask

  @moduletag timeout: 300_000

  # Two cases whose answers used tools, so six questions are asked of each.
  @cases ["calendar_tomorrow", "event_organizer"]
  @pairs 12

  @instrument %{
    model_version: "winnow:e4b",
    model_digest: "sha256:" <> String.duplicate("a", 64),
    runtime_version: "synthetic-runtime-1"
  }

  setup do
    Correlation.start_new()
    F.in_zone!()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    ctx = F.tenant!()
    fixture = Eval.seed!(ctx)
    cases = Enum.filter(Eval.cases(fixture), &(&1.id in @cases))
    results = Eval.run(ctx, cases, before_case: &ScriptedModel.script!(Eval.oracle(&1)))
    FakeReqLLM.reset_calls()

    %{ctx: ctx, results: results}
  end

  describe "without a judge instrument or an evaluation tenant" do
    test "nothing is judged and the family is printed as unmeasured, not passed",
         %{ctx: ctx, results: results} do
      for {opts, missing} <- [
            {[tenant: ctx.tenant], [:instrument]},
            {[instrument: @instrument], [:tenant]},
            {[instrument: nil, tenant: nil], [:instrument, :tenant]}
          ] do
        grade = Eval.grade(results, opts)

        assert grade.graded? == false
        assert grade.missing == missing
        assert grade.verdict == :unmeasured
      end

      assert FakeReqLLM.calls() == 0
      assert Judgment |> Ash.read!(tenant: ctx.tenant, authorize?: false) == []

      assert Eval.grade_lines(Eval.grade(results, tenant: ctx.tenant)) == [
               "judgments        agent_reply_style: unmeasured, not graded " <>
                 "(no judge instrument given). Not a pass."
             ]
    end
  end

  describe "review-band answers" do
    test "admit nothing: the family reads unmeasured, with every pair an open review",
         %{ctx: ctx, results: results} do
      run_id = run_id()

      grade = Eval.grade(results, grade_opts(ctx, run_id, &review_table/3))

      assert grade.graded?
      assert length(grade.grading) == @pairs
      assert Enum.all?(grade.grading, &match?({:ok, %{band: :review}}, &1.result))
      assert FakeReqLLM.calls() == @pairs
      assert facts(run_id) == []

      # The test database publishes no table for the family.
      report = grade.report
      assert report.verdict == :unmeasured
      assert report.verdict_reasons == [:no_published_band_table]
      assert report.review_open == @pairs
      assert report.replies == %{compliant: 0, violating: 0, unknown: 2}
      assert report.rate == 0.0

      # With a certified table the reviews still decide nothing: too many
      # unknowns, never a pass. The banded pairs are not judged again.
      again =
        Eval.grade(
          results,
          [band_table: band_table()] ++ grade_opts(ctx, run_id, &review_table/3)
        )

      assert Enum.all?(again.grading, &(&1.result == {:skipped, :already_banded}))
      assert FakeReqLLM.calls() == @pairs
      assert again.report.verdict == :unmeasured
      assert again.report.verdict_reasons == [:too_many_unknown]
      assert again.report.review_open == @pairs

      printed = Enum.join(Eval.grade_lines(again), "\n")
      assert printed =~ "agent_reply_style: unmeasured (too many unknown)"
      assert printed =~ "#{@pairs} open review(s) awaiting a person's verdict"
      assert printed =~ "0% compliant of all replies"
    end
  end

  describe "a certified, published table" do
    test "in answers on every question pass", %{ctx: ctx, results: results} do
      run_id = run_id()

      grade =
        Eval.grade(
          results,
          [band_table: band_table()] ++ grade_opts(ctx, run_id, &admit_table/3)
        )

      assert Enum.all?(grade.grading, &match?({:ok, %{band: :admit}}, &1.result))
      assert length(facts(run_id)) == @pairs

      report = grade.report
      assert report.verdict == :pass
      assert report.replies == %{compliant: 2, violating: 0, unknown: 0}
      assert report.rate == 1.0
      assert report.grading == %{judged: @pairs, judge_errors: 0, not_banded: 0}

      lines = Eval.grade_lines(grade)

      assert hd(lines) ==
               "judgments        agent_reply_style: pass; " <>
                 "shown beside the scorecard, it gates no release yet"

      printed = Enum.join(lines, "\n")
      assert printed =~ "v1, certified #{Date.to_iso8601(Date.utc_today())}"
      assert printed =~ "2 (0 with no answer to grade): 2 compliant · 0 violating · 0 unknown"
      assert printed =~ "violations     none"

      # Counts and rates only: no answer text.
      refute printed =~ "SYNTHETIC"
      refute printed =~ "Quinn"
    end

    test "an out answer on a zero-violation question fails", %{ctx: ctx, results: results} do
      run_id = run_id()

      grade =
        Eval.grade(
          results,
          [band_table: band_table()] ++ grade_opts(ctx, run_id, &hs5_out_table/3)
        )

      report = grade.report
      assert report.verdict == :fail
      assert report.verdict_reasons == [{:violation, :hs5_promise_only_agreed_to}]
      assert report.replies == %{compliant: 0, violating: 2, unknown: 0}
      assert report.per_question.hs5_promise_only_agreed_to.violating == 2

      printed = Enum.join(Eval.grade_lines(grade), "\n")
      assert printed =~ "agent_reply_style: fail (a violation of hs5_promise_only_agreed_to)"
      assert printed =~ "violations     hs5_promise_only_agreed_to 2"
    end

    test "a case with no answer to read stays in the report as an unknown reply",
         %{ctx: ctx, results: results} do
      run_id = run_id()
      results = results ++ [%{id: "no_answer_case", turn_id: nil}]

      grade =
        Eval.grade(
          results,
          [band_table: band_table()] ++ grade_opts(ctx, run_id, &admit_table/3)
        )

      assert grade.no_answer == ["agent_reply:#{run_id}/no_answer_case/1"]
      assert FakeReqLLM.calls() == @pairs

      report = grade.report
      assert report.n_subjects == 3
      assert report.replies == %{compliant: 2, violating: 0, unknown: 1}
      # One unknown in three is more than max_unknown allows: unmeasured, not a pass.
      assert report.verdict == :unmeasured
      assert report.verdict_reasons == [:too_many_unknown]
      assert_in_delta report.rate, 2 / 3, 1.0e-9
    end
  end

  describe "a model error" do
    test "is reported and not counted: no violation, no pass", %{ctx: ctx, results: results} do
      run_id = run_id()

      opts =
        [band_table: band_table()] ++
          Keyword.put(grade_opts(ctx, run_id, &admit_table/3), :judgments, %{
            req_llm: FailingReqLLM
          })

      log =
        capture_log(fn ->
          send(self(), {:grade, Eval.grade(results, opts)})
        end)

      assert_received {:grade, grade}
      assert FailingReqLLM.calls() == @pairs
      assert log =~ "judge failed, nothing recorded or admitted"

      assert Enum.all?(grade.grading, &(&1.observation_id == nil))
      assert Judgment |> Ash.read!(tenant: ctx.tenant, authorize?: false) == []
      assert facts(run_id) == []

      report = grade.report
      assert report.grading == %{judged: 0, judge_errors: @pairs, not_banded: 0}
      assert report.replies == %{compliant: 0, violating: 0, unknown: 2}
      assert report.unknown_reasons == %{no_fact: @pairs}
      assert report.verdict == :unmeasured
      assert report.verdict_reasons == [:too_many_unknown]

      printed = Enum.join(Eval.grade_lines(grade), "\n")

      assert printed =~
               "0 answered · #{@pairs} model error(s), reported and not counted " <>
                 "(those pairs read unknown)"

      assert printed =~ "violations     none"
    end
  end

  describe "the task's --judge-* flags" do
    test "give the instrument with all three, nothing with none, and stop on part of one" do
      assert EvalTask.instrument!([]) == nil
      assert EvalTask.instrument!(only: "calendar_tomorrow") == nil

      assert EvalTask.instrument!(
               judge_model_version: @instrument.model_version,
               judge_model_digest: @instrument.model_digest,
               judge_runtime_version: @instrument.runtime_version
             ) == @instrument

      assert_raise Mix.Error, ~r/needs all of .*got only --judge-model-version/, fn ->
        EvalTask.instrument!(judge_model_version: "winnow:e4b")
      end
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp run_id, do: "SYNTHETIC-eval-#{System.unique_integer([:positive])}"

  defp grade_opts(ctx, run_id, resolver) do
    [
      run_id: run_id,
      tenant: ctx.tenant,
      actor: ctx.actor,
      instrument: @instrument,
      judgments: %{req_llm: FakeReqLLM},
      resolver: resolver
    ]
  end

  defp facts(run_id) do
    prefix = "agent_reply:#{run_id}/"

    Fact
    |> Ash.Query.filter(subject_type == ^Quality.subject_type())
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&String.starts_with?(&1.subject_id, prefix))
  end

  defp band_table,
    do: %{
      definition_id: Ash.UUID.generate(),
      definition_version: "1",
      published_at: DateTime.utc_now(),
      certified_at: DateTime.utc_now()
    }

  defp review_table(_family, _tenant, _inputs), do: evaluation(%{"band" => "review"})

  defp admit_table(_family, _tenant, _inputs),
    do: evaluation(%{"band" => "admit", "fact_value" => true})

  # Admits a no on hs5 (promise only what is agreed) and a yes elsewhere.
  defp hs5_out_table(_family, _tenant, inputs) do
    value = not Map.has_key?(inputs, "hs5_promise_only_agreed_to__present")
    evaluation(%{"band" => "admit", "fact_value" => value})
  end

  defp evaluation(outputs) do
    {:ok,
     %{
       band_table: %{
         "definition_key" => "judgments_band_agent_reply_style",
         "definition_version" => "1",
         "content_hash" => "sha256:" <> String.duplicate("c", 64),
         "definition_id" => Ash.UUID.generate(),
         "tenant_fork" => nil
       },
       outputs: outputs,
       matched_rule_ids: ["rule_1"],
       decision_evaluation_id: Ash.UUID.generate()
     }}
  end
end

defmodule AshEnterprise.Quality.GraderTest do
  @moduledoc """
  S1-93: agent replies through assess, judge and admit, in a synthetic
  evaluation tenant.

  The judge path is the real one (generated judge action, host judge
  context, ledger recorder, banding step, facts materialiser) with the
  model replaced by `FakeReqLLM` (or `FailingReqLLM`) and the band table by
  a stub resolver where a test needs one. No model is called. Threads and
  text are synthetic.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshEnterprise.Assistant.{Thread, Turn}
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Gate, Grader, Questions}
  alias AshEnterprise.SystemOne.{Banding, Fact, Judgment}
  alias AshEnterprise.SystemOne.TestSupport.{FailingReqLLM, FakeReqLLM}
  alias AshEnterprise.Test.AssistantFixtures, as: F

  @answer "The SYNTHETIC launch checklist is due on 2026-11-06."

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    ctx = F.tenant!()
    {:ok, thread} = Thread.start("SYNTHETIC thread", actor: ctx.actor, tenant: ctx.tenant)

    Map.merge(ctx, %{
      thread: thread,
      run_id: "SYNTHETIC-run-#{System.unique_integer([:positive])}"
    })
  end

  describe "a family with no published band table" do
    test "judges and records each question, admits nothing, and every pair reads :no_fact",
         ctx do
      reply = reply!(ctx, "due_soon", %{content: @answer})

      results = Grader.grade([reply], tenant: ctx.tenant, judgments: %{req_llm: FakeReqLLM})

      assert Enum.map(results, & &1.question) == Questions.names()
      assert Enum.all?(results, &(&1.reason == :no_fact))
      assert Enum.all?(results, &match?({:error, _}, &1.result))
      assert FakeReqLLM.calls() == 8

      # Each answer is a ledger row under the reply's subject term, with the
      # text the model judged sealed on it.
      rows = judgments(ctx, reply)
      assert MapSet.new(rows, & &1.id) == MapSet.new(results, & &1.observation_id)
      assert Enum.all?(rows, &(&1.state_digest == Quality.digest(reply)))
      assert Enum.all?(rows, &is_binary(&1.state_ciphertext))

      assert facts(reply) == []

      report = Gate.family_report([reply], :agent_reply_style, tenant: ctx.tenant)
      assert report.band_table == nil
      assert report.unknown_reasons == %{no_fact: 8}
      assert report.replies == %{compliant: 0, violating: 0, unknown: 1}
      assert report.review_open == 0
      assert report.verdict == :unmeasured
      assert report.verdict_reasons == [:no_published_band_table]

      # Never banded, so the next run asks again.
      again = Grader.grade([reply], tenant: ctx.tenant, judgments: %{req_llm: FakeReqLLM})
      assert length(again) == 8
      assert FakeReqLLM.calls() == 16
    end
  end

  describe "review-band answers" do
    test "admit nothing, are not asked again while the text is unchanged, and read as open reviews",
         ctx do
      reply = reply!(ctx, "due_soon", %{content: @answer})
      opts = grade_opts(ctx, &review_table/3)

      results = Grader.grade([reply], opts)

      assert length(results) == 8
      assert Enum.all?(results, &match?({:ok, %{band: :review}}, &1.result))
      assert facts(reply) == []

      reviews =
        Banding
        |> Ash.Query.filter(band == :review)
        |> Ash.read!(tenant: ctx.tenant, authorize?: false)

      assert length(reviews) == 8

      # No fact, so the pairs are still pending; each is skipped, not judged.
      assert length(Grader.assess([reply])) == 8
      skipped = Grader.grade([reply], opts)
      assert Enum.all?(skipped, &(&1.result == {:skipped, :already_banded}))

      assert Enum.map(skipped, & &1.observation_id) == Enum.map(results, & &1.observation_id)

      assert FakeReqLLM.calls() == 8

      report = Gate.family_report([reply], :agent_reply_style, tenant: ctx.tenant)
      assert report.review_open == 8
      assert report.unknown_reasons == %{no_fact: 8}
      assert report.rate == 0.0
    end
  end

  describe "a model error" do
    test "is returned and logged, records no judgment and admits nothing", ctx do
      reply = reply!(ctx, "due_soon", %{content: @answer})
      opts = Keyword.put(grade_opts(ctx, &admit_table/3), :judgments, %{req_llm: FailingReqLLM})

      log =
        capture_log(fn ->
          results = Grader.grade([reply], opts)
          send(self(), {:results, results})
        end)

      assert_received {:results, results}

      assert length(results) == 8
      assert Enum.all?(results, &(&1.observation_id == nil))
      assert Enum.all?(results, &match?({:error, _}, &1.result))
      assert FailingReqLLM.calls() == 8

      assert judgments(ctx, reply) == []
      assert facts(reply) == []

      assert log =~ "agent reply #{reply.id}: the hs1_lead_with_outcome_or_ask judge failed"
      refute log =~ "SYNTHETIC launch checklist"

      report =
        Gate.family_report([reply], :agent_reply_style, tenant: ctx.tenant, grading: results)

      assert report.grading == %{judged: 0, judge_errors: 8, not_banded: 0}
      assert report.unknown_reasons == %{no_fact: 8}
    end
  end

  describe "admitted answers" do
    test "write a fact per question with the reply's digest; a re-run finds nothing pending",
         ctx do
      reply = reply!(ctx, "due_soon", %{content: @answer})

      results = Grader.grade([reply], grade_opts(ctx, &admit_table/3))

      assert Enum.all?(results, &match?({:ok, %{band: :admit}}, &1.result))

      facts = facts(reply)
      assert length(facts) == 8
      assert Enum.all?(facts, &(&1.subject_state_digest == Quality.digest(reply)))
      assert Enum.all?(facts, &(&1.holds == true))

      assert Grader.assess([reply]) == []
      assert Grader.grade([reply], grade_opts(ctx, &admit_table/3)) == []
      assert FakeReqLLM.calls() == 8

      report =
        Gate.family_report([reply], :agent_reply_style,
          tenant: ctx.tenant,
          band_table: band_table(),
          grading: results
        )

      assert report.replies == %{compliant: 1, violating: 0, unknown: 0}
      assert report.grading == %{judged: 8, judge_errors: 0, not_banded: 0}
      assert report.verdict == :pass
    end

    test "a reply that used tools is asked six questions, not hs4 or hs7", ctx do
      reply =
        reply!(ctx, "cited", %{
          content: "Rory asked about it [[conversation:SYNTHETIC]].",
          refs: ["conversation:SYNTHETIC"]
        })

      results = Grader.grade([reply], grade_opts(ctx, &admit_table/3))

      names = Enum.map(results, & &1.question)
      assert length(names) == 6
      refute :hs4_claim_only_built_and_proven in names
      refute :hs7_never_invent_name_feature_or_date in names
    end
  end

  describe "evaluation replies only" do
    test "a reply named by its turn alone is refused before anything is judged", ctx do
      turn = append!(ctx, %{role: :assistant, content: @answer})
      {:ok, reply} = Quality.reply_from_turn(turn.id, actor: ctx.actor, tenant: ctx.tenant)

      assert reply.id == "assistant_turn:#{turn.id}"

      assert_raise ArgumentError, ~r/only evaluation replies/, fn ->
        Grader.grade([reply], grade_opts(ctx, &admit_table/3))
      end

      assert FakeReqLLM.calls() == 0
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp append!(ctx, attrs) do
    attrs
    |> Map.put(:thread_id, ctx.thread.id)
    |> Turn.append!(actor: ctx.actor, tenant: ctx.tenant)
  end

  defp reply!(ctx, case_id, attrs) do
    turn = append!(ctx, Map.put(attrs, :role, :assistant))

    {:ok, reply} =
      Quality.reply_from_turn(turn.id, %{run_id: ctx.run_id, case_id: case_id, epoch: 1},
        actor: ctx.actor,
        tenant: ctx.tenant
      )

    reply
  end

  defp grade_opts(ctx, resolver),
    do: [tenant: ctx.tenant, judgments: %{req_llm: FakeReqLLM}, resolver: resolver]

  defp judgments(ctx, reply) do
    Judgment
    |> Ash.Query.filter(subject_type == ^Quality.subject_type() and subject_id == ^reply.id)
    |> Ash.read!(tenant: ctx.tenant, authorize?: false)
  end

  defp facts(reply) do
    Fact
    |> Ash.Query.filter(subject_type == ^Quality.subject_type() and subject_id == ^reply.id)
    |> Ash.read!(authorize?: false)
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

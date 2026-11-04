defmodule AshEnterprise.Quality.JudgedScoresTest do
  @moduledoc """
  Model-graded scores beside the deterministic ones (ADR 0058, decision D9): each carries
  the judgment ledger rows that judged the reply and the family's certification status,
  and none of them gates. The judge is `FakeReqLLM` and the band table a stub: no model
  is called. Text is synthetic.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Assistant.{Thread, Turn}
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Gate, Grader, JudgedScores, Questions}
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM
  alias AshEnterprise.Test.AssistantFixtures, as: F

  @instrument %{
    model_version: "winnow:12b",
    model_digest: "sha256:" <> String.duplicate("a", 64),
    runtime_version: "synthetic-runtime-1"
  }

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
    run_id = "SYNTHETIC-run-#{System.unique_integer([:positive])}"

    replies =
      for id <- ["case_a", "case_b"] do
        turn =
          Turn.append!(
            %{thread_id: thread.id, role: :assistant, content: "SYNTHETIC answer for #{id}."},
            actor: ctx.actor,
            tenant: ctx.tenant
          )

        {:ok, reply} =
          Quality.reply_from_turn(turn.id, %{run_id: run_id, case_id: id, epoch: 1},
            actor: ctx.actor,
            tenant: ctx.tenant
          )

        reply
      end

    Map.merge(ctx, %{replies: replies})
  end

  defp grade!(ctx) do
    Grader.grade(ctx.replies,
      tenant: ctx.tenant,
      instrument: @instrument,
      judgments: %{req_llm: FakeReqLLM},
      resolver: &admit_table/3
    )
  end

  defp build(ctx, grading, band_table) do
    report =
      Gate.family_report(ctx.replies, :agent_reply_style,
        tenant: ctx.tenant,
        grading: grading,
        band_table: band_table
      )

    {report, JudgedScores.build(ctx.replies, report, tenant: ctx.tenant)}
  end

  test "a score per question and case, carrying the ledger rows that judged it", ctx do
    grading = grade!(ctx)
    {_report, %{scores: scores, report: summary}} = build(ctx, grading, band_table())

    assert Map.keys(scores) |> Enum.sort() == ["case_a", "case_b"]

    for {case_id, reply} <- Enum.zip(["case_a", "case_b"], ctx.replies) do
      case_scores = scores[case_id]

      assert Enum.map(case_scores, & &1["scorer"]) |> Enum.sort() ==
               Enum.map(Questions.names(), &"agent_reply_style/#{&1}") |> Enum.sort()

      # The ledger ids are the judgments the grader recorded for this reply.
      recorded = for e <- grading, e.reply_id == reply.id, do: e.observation_id

      assert Enum.flat_map(case_scores, & &1["judgment_ids"]) |> Enum.sort() ==
               Enum.sort(recorded)

      for score <- case_scores do
        assert score["kind"] == "judged"
        assert score["status"] == "compliant"
        assert score["gates"] == false
        assert %{"status" => "certified", "band_table_version" => "1"} = score["certification"]
        assert is_binary(score["question_hash"])
      end
    end

    assert summary["gates"] == false
    assert summary["family"] == "agent_reply_style"
    assert summary["certification"]["status"] == "certified"
    assert summary["replies"] == %{"compliant" => 2, "violating" => 0, "unknown" => 0}
    assert is_map(JSON.decode!(JSON.encode!(summary)))
  end

  test "says why a score is shown without weight: no band table, not certified, too old", ctx do
    grading = grade!(ctx)

    cert = fn table ->
      {_report, %{scores: scores, report: summary}} = build(ctx, grading, table)
      assert summary["certification"] == hd(scores["case_a"])["certification"]
      summary["certification"]["status"]
    end

    assert cert.(nil) == "no_published_band_table"
    assert cert.(%{band_table() | certified_at: nil}) == "not_certified"

    assert cert.(%{band_table() | certified_at: DateTime.add(DateTime.utc_now(), -400, :day)}) ==
             "band_table_too_old"
  end

  test "a reply no judge has read is unknown with its reason, and no ledger rows", ctx do
    {_report, %{scores: scores}} = build(ctx, [], band_table())

    for score <- scores["case_a"] do
      assert score["status"] == "unknown"
      assert score["unknown_reason"] == "no_fact"
      assert score["judgment_ids"] == []
    end
  end

  test "case_id reads the case an evaluation reply is named for" do
    assert JudgedScores.case_id("agent_reply:run-1/calendar_tomorrow/1") == "calendar_tomorrow"
    assert JudgedScores.case_id("assistant_turn:abc") == nil
  end

  defp band_table,
    do: %{
      definition_id: Ash.UUID.generate(),
      definition_version: "1",
      published_at: DateTime.utc_now(),
      certified_at: DateTime.utc_now()
    }

  defp admit_table(_family, _tenant, _inputs),
    do:
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

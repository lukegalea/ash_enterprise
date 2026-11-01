defmodule AshEnterprise.Quality.ReviewVerdictTest do
  @moduledoc """
  S1-96: a review-band agent reply in the evaluation tenant is judged by a
  person on the verdicts surface (`/app/judgments`, ADR 0061), and the
  verdict moves the quality gate.

  The path is the real one end to end, with only the model replaced
  (`FakeReqLLM`, which answers every yes/no question at 0.9): the grader
  judges and records the reply, a published `agent_reply_style` band
  table (rendered by `ProposalDmn`, resolved by the default resolver)
  bands each answer `review`, the surface shows the row with the reply
  text the ledger sealed, and the person's click through
  `AshA2ui.ActionHandler` records the verdict, which is admitted as the
  reply's fact at person grade. `AshEnterprise.Quality.Gate.family_report/3`
  then counts it. Threads and text are synthetic.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Assistant.{Thread, Turn}
  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Gate, Grader, Questions}
  alias AshEnterprise.Quality.Projections.ReplyText
  alias AshEnterprise.SystemOne.{Banding, Fact, HumanVerdict, Judgment}
  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterpriseWeb.A2ui.Judgments.VerdictsUI

  @kept "The SYNTHETIC launch checklist is due on 2026-11-06."
  @broken "The SYNTHETIC launch will ship next week with every feature."

  @instrument %{
    model_version: "winnow:e4b",
    model_digest: "sha256:" <> String.duplicate("a", 64),
    runtime_version: "synthetic-runtime-1"
  }

  @row_fields [:subject, :question, :question_text, :lean, :judged_text, :judged_excerpt]

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()
    AshEnterprise.Process.Resolver.forget_platform_tenant()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
      AshEnterprise.Process.Resolver.forget_platform_tenant()
    end)

    ctx = F.tenant!()
    {:ok, thread} = Thread.start("SYNTHETIC thread", actor: ctx.actor, tenant: ctx.tenant)

    # FakeReqLLM answers yes at 0.9: inside the table's review band.
    publish_band_table!(%{"threshold" => "0.95", "threshold_low" => "0.05"})

    Map.merge(ctx, %{
      thread: thread,
      run_id: "SYNTHETIC-run-#{System.unique_integer([:positive])}"
    })
  end

  test "a review-band reply is shown on the verdicts surface, and a person's verdict moves the gate",
       ctx do
    kept = reply!(ctx, "kept", @kept)
    broken = reply!(ctx, "broken", @broken)

    # -- the grader bands every answer review: nothing admitted ---------------

    results = Grader.grade([kept, broken], grade_opts(ctx))
    assert length(results) == 16
    assert Enum.all?(results, &match?({:ok, %{band: :review}}, &1.result))
    assert facts(kept) == [] and facts(broken) == []

    before = Gate.family_report([kept, broken], :agent_reply_style, tenant: ctx.tenant)
    assert before.replies == %{compliant: 0, violating: 0, unknown: 2}
    assert before.review_open == 16
    assert before.unknown_reasons == %{no_fact: 16}

    # -- the verdicts surface shows each pair, with the reply text --------------

    rows = awaiting(ctx)
    assert length(rows) == 16

    hs1 = Questions.declared(:hs1_lead_with_outcome_or_ask)
    row = row_for(rows, kept, :hs1_lead_with_outcome_or_ask)

    assert row.question_text == hs1.instructions
    # The ledger sealed {"reply": text}; the person reads the reply.
    assert row.judged_text == @kept
    assert row.judged_excerpt == @kept
    assert row.lean =~ "leans yes, 0.9"
    assert row.lean =~ "0.95 admits yes and 0.05 admits no without review"

    surface =
      inspect(AshA2ui.Info.build_data_model(VerdictsUI, actor: ctx.actor, tenant: ctx.tenant))

    assert surface =~ @kept
    assert surface =~ @broken
    assert surface =~ kept.id
    assert surface =~ hs1.instructions
    refute surface =~ ~s({\\"reply\\")

    # -- the person records verdicts from the surface ---------------------------

    # Every question on the kept reply: yes.
    for name <- Questions.for_reply(kept) do
      assert {:ok, _messages} =
               record_verdict(ctx, row_for(rows, kept, name), "yes", "Meets the standard.")
    end

    # One question on the broken reply: no. It promises a date nobody agreed.
    hs5 = :hs5_promise_only_agreed_to

    assert {:ok, _messages} =
             record_verdict(ctx, row_for(rows, broken, hs5), "no", "Promises an unagreed date.")

    assert length(awaiting(ctx)) == 7

    # -- each verdict is the reply's fact, at person grade ---------------------

    kept_facts = facts(kept)
    assert length(kept_facts) == 8
    assert Enum.all?(kept_facts, &(&1.admission_grade == :person))
    assert Enum.all?(kept_facts, &(&1.holds == true and &1.value == true))
    assert Enum.all?(kept_facts, &(&1.subject_state_digest == Quality.digest(kept)))

    verdict_ids = HumanVerdict |> Ash.read!(tenant: ctx.tenant, authorize?: false) |> ids()
    assert kept_facts |> ids(:admission_id) |> MapSet.subset?(verdict_ids)

    assert [broken_fact] = facts(broken)
    assert broken_fact.predicate == Grader.predicate(hs5)
    assert {broken_fact.value, broken_fact.holds} == {false, false}
    assert broken_fact.admission_grade == :person

    # -- the gate counts them, at either grade floor ---------------------------

    for min_grade <- [:grant, :person] do
      report =
        Gate.family_report([kept, broken], :agent_reply_style,
          tenant: ctx.tenant,
          min_grade: min_grade
        )

      assert report.replies == %{compliant: 1, violating: 1, unknown: 0}, inspect(min_grade)
      assert report.per_question[hs5].in == 1
      assert report.per_question[hs5].out == 1
      assert report.per_question[:hs1_lead_with_outcome_or_ask].unknown == 1
      assert report.review_open == 7
      assert report.unknown_reasons == %{no_fact: 7}
      assert report.rate == 0.5
      assert report.decided_rate == 0.5

      # The published table carries no certification here, so nothing gates.
      assert {report.verdict, report.verdict_reasons} == {:unmeasured, [:not_certified]}
    end

    # With a current certification, the decided violation on hs5 fails it.
    certified =
      Gate.family_report([kept, broken], :agent_reply_style,
        tenant: ctx.tenant,
        band_table: certified_band_table()
      )

    assert {certified.verdict, certified.verdict_reasons} == {:fail, [{:violation, hs5}]}

    # The grader asks the kept reply nothing more, and leaves the broken
    # reply's open reviews waiting rather than judging them again.
    assert Grader.assess([kept]) == []
    calls = FakeReqLLM.calls()
    rerun = Grader.grade([broken], grade_opts(ctx))
    assert length(rerun) == 7
    assert Enum.all?(rerun, &(&1.result == {:skipped, :already_banded}))
    assert FakeReqLLM.calls() == calls
  end

  test "a verdict that is not a review admits nothing: a calibration label stays a label", ctx do
    reply = reply!(ctx, "label", @kept)
    [entry | _] = Grader.grade([reply], grade_opts(ctx))
    judgment = Ash.get!(Judgment, entry.observation_id, tenant: ctx.tenant, authorize?: false)

    HumanVerdict
    |> Ash.Changeset.for_create(
      :record,
      %{
        judgment_id: judgment.id,
        question_hash: judgment.question_hash,
        model_answer: %{"kind" => "noul", "value" => nil},
        human_value: "true",
        reviewer: to_string(ctx.user.email),
        basis: :labelling
      },
      actor: ctx.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()

    assert facts(reply) == []

    report = Gate.family_report([reply], :agent_reply_style, tenant: ctx.tenant)
    assert report.replies.unknown == 1
  end

  test "the review source shows a reply's sealed state as its text, and anything else as sealed" do
    state = ReplyText.state(%{text: @kept})
    sealed = AshEnterprise.SystemOne.JudgedState.text(state)

    assert sealed =~ ~s("reply")
    assert ReplyText.text_of_sealed(sealed) == @kept

    assert ReplyText.text_of_sealed(~s({"reply":"a","other":"b"})) ==
             ~s({"reply":"a","other":"b"})

    assert ReplyText.text_of_sealed("plain text") == "plain text"
  end

  # -- helpers ------------------------------------------------------------------

  defp reply!(ctx, case_id, content) do
    turn =
      Turn.append!(%{thread_id: ctx.thread.id, role: :assistant, content: content},
        actor: ctx.actor,
        tenant: ctx.tenant
      )

    {:ok, reply} =
      Quality.reply_from_turn(turn.id, %{run_id: ctx.run_id, case_id: case_id, epoch: 1},
        actor: ctx.actor,
        tenant: ctx.tenant
      )

    reply
  end

  defp grade_opts(ctx),
    do: [tenant: ctx.tenant, instrument: @instrument, judgments: %{req_llm: FakeReqLLM}]

  defp awaiting(ctx) do
    Banding
    |> Ash.Query.for_read(:awaiting_verdict, %{}, actor: ctx.actor, tenant: ctx.tenant)
    |> Ash.Query.load(@row_fields)
    |> Ash.read!()
  end

  defp row_for(rows, reply, name) do
    name = Atom.to_string(name)
    Enum.find(rows, &(&1.subject == reply.id and &1.question == name)) || flunk("no row")
  end

  # The surface's own act, clicked as the person.
  defp record_verdict(ctx, row, answer, why) do
    AshA2ui.ActionHandler.handle(
      VerdictsUI,
      %{
        "name" => "invoke",
        "context" => %{
          "action" => "record_verdict",
          "recordId" => row.id,
          "component" => "table",
          "values" => %{"answer" => answer, "why" => why}
        }
      },
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp facts(reply) do
    Fact
    |> Ash.Query.filter(subject_type == ^Quality.subject_type() and subject_id == ^reply.id)
    |> Ash.read!(authorize?: false)
  end

  defp ids(records, field \\ :id), do: MapSet.new(records, &Map.fetch!(&1, field))

  # A version of the family's band table as the certify act publishes one,
  # in the platform organization, where the default resolver finds it.
  defp publish_band_table!(thresholds) do
    platform = Seeder.seed_platform_organization()
    key = Resolver.band_table_key(to_string(Questions.family()))

    {:ok, xml} =
      AshJudgments.Calibration.ProposalDmn.render(
        %{
          "definition_key" => key,
          "family_tag" => "judgments:family:#{Questions.family()}",
          "thresholds" => thresholds
        },
        score_input: Questions.score_inputs(),
        low_band: :admit_no
      )

    Definition.create!(%{key: key, name: key, xml: xml}, authorize?: false, tenant: platform.id)
    |> Definition.publish!(authorize?: false, tenant: platform.id)
  end

  defp certified_band_table,
    do: %{
      definition_id: Ash.UUID.generate(),
      definition_version: "1",
      published_at: DateTime.utc_now(),
      certified_at: DateTime.utc_now()
    }
end

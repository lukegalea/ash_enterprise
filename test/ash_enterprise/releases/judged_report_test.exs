defmodule AshEnterprise.Releases.JudgedReportTest do
  @moduledoc """
  S1-97 under ADR 0058 decision D9: judged scores report and never gate.

  A suite naming the `agent_reply_style` scorer is run with `start` against an agent that
  answers in words. Each case's answer is a reply subject (`AgentReply`'s `:from_run`),
  so `finish` reports the judged scores the admitted facts give it. The family's band
  table is published and certified (by a person in their own tenant), and one answer
  violates hs5: the family's report fails. The release manifest carries that report, and
  the release gate passes on the deterministic results exactly as it would without it.
  The facts are written straight through the materialiser; no judge is asked. Every name
  and sentence is synthetic.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs, except: [agent: 0]

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Release.Gate, as: ReleaseGate
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Grader, Questions, SuiteGate}
  alias AshEnterprise.Test.Execution.{Authority, NoNetwork, Releases}
  alias AshEnterprise.Test.Quality.{BandTables, ReferralReplier}
  alias AshJudgments.Facts.Materialiser

  @agent "clinic.referral_replier"

  setup do
    in_zone!()
    pause_queues!()
    :ok = NoNetwork.block!()
    clinic = clinic!()
    Authority.start_grant!(clinic.admin, clinic.admin, @agent)
    %{clinic: clinic}
  end

  defp suite!(clinic) do
    cases =
      for id <- ["promises-a-date", "not-yet-judged"] do
        %{
          id: id,
          input: "SYNTHETIC: when will patient 7's referral be sent?",
          assertions: [%{type: :max_steps, limit: 4}]
        }
      end

    opts = [actor: clinic.admin.actor, tenant: clinic.tenant]

    "clinic.replies"
    |> Quality.create_suite_draft!(
      %{cases: cases, scorers: [%{"kind" => "judged", "family" => "agent_reply_style"}]},
      opts
    )
    |> Quality.publish_suite!(opts)
  end

  # Starts the suite run on `manifest` and drives each case's run to its answer; the
  # suite run is not finished yet.
  defp started!(clinic, suite, manifest) do
    suite_run =
      Quality.start_suite_run!(suite.id, @agent, %{release_manifest_id: manifest.id},
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    for case_id <- ["promises-a-date", "not-yet-judged"] do
      script!([{:text, "SYNTHETIC: the referral for patient 7 will be sent on 2026-12-01."}])
      assert drive!(case_run(clinic, suite_run, case_id)).status == :completed
    end

    suite_run
  end

  defp drive!(run) do
    Enum.reduce_while(1..4, run, fn _round, run ->
      step!(run)
      Oban.drain_queue(queue: :execution)
      run = run(run)
      if run.status in [:completed, :failed, :cancelled], do: {:halt, run}, else: {:cont, run}
    end)
  end

  defp case_run(clinic, suite_run, case_id) do
    [run] =
      Execution.list_agent_runs!(
        query: [filter: [run_key: Quality.SuiteRun.run_key(suite_run.id, case_id, 1)]],
        authorize?: false,
        tenant: clinic.tenant
      )

    run
  end

  defp reply!(clinic, suite_run, case_id) do
    run = case_run(clinic, suite_run, case_id)

    Quality.reply_from_run!(run.id, %{run_id: suite_run.id, case_id: case_id, epoch: 1},
      actor: oban(clinic.tenant)[:actor],
      tenant: clinic.tenant
    )
  end

  # Every question compliant except `violating`, at person grade, on the reply's text.
  defp judged!(reply, violating) do
    for name <- Questions.names() do
      value = name != violating

      assert {:ok, :materialised} =
               Materialiser.materialise(%{
                 result: :admitted,
                 subject: Quality.subject_term(reply),
                 predicate: Grader.predicate(name),
                 value: value,
                 holds: value,
                 grade: :person,
                 admission_id: Ash.UUID.generate(),
                 subject_state_digest: Quality.digest(reply)
               })
    end
  end

  test "a certified family that fails is reported on the manifest and the gate passes as before",
       %{clinic: clinic} do
    published!(clinic, %{}, ReferralReplier)
    suite = suite!(clinic)
    BandTables.certify!(BandTables.published!())

    manifest =
      Releases.resolved!(clinic, "clinic.replies", [
        %{kind: "agent", key: @agent},
        %{kind: "suite", key: "clinic.replies"}
      ])

    suite_run = started!(clinic, suite, manifest)

    # The run's answer is the reply subject the suite run names, with the answer's text.
    reply = reply!(clinic, suite_run, "promises-a-date")
    assert reply.id == "agent_reply:#{suite_run.id}/promises-a-date/1"
    assert reply.text =~ "will be sent on 2026-12-01"
    assert reply.agent_run_id == case_run(clinic, suite_run, "promises-a-date").id
    refute reply.used_tools

    judged!(reply, :hs5_promise_only_agreed_to)

    AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
    finished = Quality.get_suite_run!(suite_run.id, oban(clinic.tenant))

    # The judged report: certified, and failed on the decided hs5 violation.
    judged = finished.summary["judged"]
    assert judged["certification"]["status"] == "certified"
    assert judged["verdict"] == "fail"
    assert judged["verdict_reasons"] == ["violation:hs5_promise_only_agreed_to"]
    assert judged["gates"] == false
    assert judged["per_question"]["hs5_promise_only_agreed_to"]["violating"] == 1
    assert judged["replies"] == %{"compliant" => 0, "violating" => 1, "unknown" => 1}

    scores =
      Map.new(
        Quality.list_case_results!(
          query: [filter: [suite_run_id: suite_run.id]],
          authorize?: false,
          tenant: clinic.tenant
        ),
        &{&1.case_id, Map.new(&1.scores, fn score -> {score["scorer"], score} end)}
      )

    hs5 = "agent_reply_style/hs5_promise_only_agreed_to"
    assert scores["promises-a-date"][hs5]["status"] == "violating"

    # The answer no judge has read is unknown, with its reason: never a pass.
    for {_scorer, score} <- scores["not-yet-judged"] do
      assert {score["status"], score["unknown_reason"]} == {"unknown", "no_fact"}
    end

    # The deterministic results pass, and so does the release gate: the judged report
    # rides along as information.
    assert finished.summary["quality"]["pass_rate"] == 1.0
    assert {:ok, _asked} = Releases.request(clinic, manifest)

    requested = Releases.reload(clinic, manifest)
    assert requested.status == :requested
    assert requested.gate_result["passed"] == true
    assert requested.gate_result["problems"] == []

    [entry] = requested.gate_result["suites"]
    assert entry["judged"] == judged
    assert {entry["result"], entry["reasons"]} == {"pass", []}

    # Without the judged report the gate's answer is the same in every part but the report.
    case_results =
      Quality.list_case_results!(
        query: [filter: [suite_run_id: suite_run.id]],
        authorize?: false,
        tenant: clinic.tenant
      )

    unjudged = %{finished | summary: Map.delete(finished.summary, "judged")}

    assert SuiteGate.result(suite, finished, case_results) ==
             SuiteGate.result(suite, unjudged, Enum.map(case_results, &%{&1 | scores: []}))

    checked = ReleaseGate.check(requested, clinic.tenant)
    assert checked["passed"] == true
    assert Enum.map(checked["suites"], &Map.delete(&1, "judged")) == [Map.delete(entry, "judged")]
  end
end

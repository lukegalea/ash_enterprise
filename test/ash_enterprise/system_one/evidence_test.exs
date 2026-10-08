defmodule AshEnterprise.SystemOne.EvidenceTest do
  @moduledoc """
  The adjudication orchestrator (AST-152): call shape A (per-candidate
  Evidence, batched under the profile cap with no loss, packet-narrowed
  citations), call shape B (tagged-id Choice localisation + existence
  Noul), the proof-growth loop with budget + `expansion_steps` recording,
  the inputs-only assertion create — and AC-2: an AshEvents replay of an
  assertion-creating run rebuilds the row byte-identically with ZERO model
  calls.

  The instrument is the host's FakeReqLLM standing behind the real
  judge→recorder path; the run replies come from the recorded transcripts
  under `test/fixtures/system_one/evidence/recordings/` (substituted with
  the run's atom ids where a recorded citation names one). The
  reachable-instrument contract test (local Ollaya) is excluded from
  ordinary runs — `--only instrument_contract` — the family's convention.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.SystemOne.Evidence
  alias AshEnterprise.SystemOne.EvidenceAssertion
  alias AshEnterprise.SystemOne.Judgment
  alias AshEnterprise.SystemOne.TestSupport.EvidenceFile
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM
  alias AshEvidence.Assertions

  require Ash.Query

  @resource EvidenceFile

  setup do
    Correlation.start_new()

    System.put_env("OLLAYA_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")

    on_exit(fn ->
      System.delete_env("OLLAYA_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
      FakeReqLLM.clear_replies()
    end)

    FakeReqLLM.clear_replies()
    FakeReqLLM.reset_calls()

    # The evidence package's repo rides the SAME database; its own sandbox
    # owner (no FKs cross the packages — the assertion's references are
    # deliberately opaque — so two parallel sandbox transactions are fine).
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(AshEvidence.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    doc = evidence_document(["«a1» synthetic text one", "«a2» synthetic text two"])

    %{
      org: Ash.UUID.generate(),
      version_id: doc.version_id,
      atom_ids: doc.atom_ids
    }
  end

  defp shape_a_opts(ctx, overrides \\ []) do
    [
      tenant: ctx.org,
      subject: %{type: "document", id: "doc-1"},
      predicate:
        "judgment:v0:AshEnterprise.SystemOne.TestSupport.EvidenceFile#judgments/packet_supports",
      claim: "synthetic",
      document_version_id: ctx.version_id,
      call_shape: :candidate_local,
      resource: @resource,
      question: :packet_supports,
      profile: :laya_cpu,
      judgments: %{req_llm: FakeReqLLM}
    ]
    |> Keyword.merge(overrides)
  end

  defp shape_b_opts(ctx, overrides \\ []) do
    [
      tenant: ctx.org,
      subject: %{type: "document", id: "doc-1"},
      predicate:
        "judgment:v0:AshEnterprise.SystemOne.TestSupport.EvidenceFile#judgments/document_contains",
      claim: "synthetic",
      document_version_id: ctx.version_id,
      call_shape: :whole_document,
      resource: @resource,
      localisation_question: :document_localisation,
      existence_question: :document_contains,
      profile: :laya_cpu,
      judgments: %{req_llm: FakeReqLLM}
    ]
    |> Keyword.merge(overrides)
  end

  defp evidence_question do
    AshJudgments.Registry.Info.question(@resource, :packet_supports)
  end

  defp assertion_rows do
    EvidenceAssertion |> Ash.read!(authorize?: false)
  end

  defp packets do
    AshEvidence.Packet |> Ash.read!(authorize?: false)
  end

  defp evaluations do
    AshEvidence.EvidenceEvaluation |> Ash.read!(authorize?: false)
  end

  ## Call shape A — per-candidate Evidence

  describe "call shape A (per-candidate Evidence)" do
    @tag :evidence_shape_a
    test "a supporting packet closes ok, joins the ledger and records the assertion", ctx do
      [a1, a2] = ctx.atom_ids

      FakeReqLLM.queue_replies([
        fixture_reply("evidence-supports.json", atom_id: a1),
        fixture_reply("evidence-supports.json", atom_id: a2)
      ])

      assert {:ok, summary} = Evidence.adjudicate(shape_a_opts(ctx))

      # The evaluation is the run row: closed ok, terminal, identified.
      assert summary.evaluation.status == :ok
      refute is_nil(summary.evaluation.closed_at)
      assert summary.evaluation.call_shape == :candidate_local
      assert summary.evaluation.profile == "laya_cpu"
      assert summary.evaluation.predicate =~ "packet_supports"
      assert summary.disposition == :supports

      # Two candidates, two judged answers, two ledger rows — every
      # candidate's citation narrows to the packet.
      assert length(summary.observation_ids) == 2

      rows =
        Judgment
        |> Ash.Query.filter(id in ^summary.observation_ids)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 2

      Enum.each(rows, fn row ->
        assert row.answer_kind == :evidence
        assert row.value == "supports"
        # The recorded atoms are the reply's own CITATION (§5.5 lists
        # source_ids for evidence) — one cited atom per recorded reply
        # here, and every citation is inside the packet.
        assert length(row.atom_ids) == 1
        assert hd(row.atom_ids) in ctx.atom_ids
      end)

      # The packet references; it never copies. Each candidate joins the
      # observation that judged it, and the selection is the union of the
      # cited atoms.
      assert [packet] = packets()
      assert packet.evaluation_id == summary.evaluation.id
      assert packet.candidate_atom_ids |> Enum.sort() == Enum.sort(ctx.atom_ids)
      assert packet.selected_atom_ids |> Enum.sort() == Enum.sort(ctx.atom_ids)
      assert packet.requires_expansion == false
      assert packet.limiting_atom_ids == []

      question_hash = evidence_question().question_hash

      for {atom_id, join} <- packet.candidate_observations do
        assert join["question_hash"] == question_hash
        assert join["observation_id"] in summary.observation_ids
        assert atom_id in ctx.atom_ids
      end

      # The assertion: the aggregate on the host base.
      assert %EvidenceAssertion{} = summary.assertion
      assert summary.assertion.disposition == :supports
      assert summary.assertion.distribution["supports"] == "0.82"
      assert summary.assertion.aggregation_rule_version == Assertions.Aggregation.version()
      assert summary.assertion.observation_ids == summary.observation_ids
      assert summary.assertion.packet_id == packet.id
      assert summary.assertion.evaluation_id == summary.evaluation.id
      assert summary.assertion.question_set_hash == summary.evaluation.question_set_hash
      assert summary.assertion.subject_state_digest =~ "sha256:"

      # The record verifies against its own inputs (§4.5) — envelope-class.
      hash =
        Assertions.record_hash(%{
          id: summary.assertion.id,
          record_version: summary.assertion.record_version,
          packet_id: summary.assertion.packet_id,
          evaluation_id: summary.assertion.evaluation_id,
          disposition: summary.assertion.disposition,
          distribution: summary.assertion.distribution,
          aggregation_rule_version: summary.assertion.aggregation_rule_version,
          observation_ids: summary.assertion.observation_ids,
          subject: summary.assertion.subject,
          predicate: summary.assertion.predicate,
          subject_state_digest: summary.assertion.subject_state_digest,
          question_set_hash: summary.assertion.question_set_hash
        })

      assert hash == summary.assertion.record_hash
    end

    @tag :evidence_shape_a
    test "batching honours the per-call cap with no loss (AC-5)", ctx do
      doc =
        evidence_document([
          "synthetic text three",
          "synthetic text four",
          "synthetic text five"
        ])

      [a1, a2, a3] = doc.atom_ids

      FakeReqLLM.queue_replies([
        fixture_reply("evidence-supports.json", atom_id: a1),
        fixture_reply("evidence-supports.json", atom_id: a2),
        fixture_reply("evidence-supports.json", atom_id: a3)
      ])

      opts =
        shape_a_opts(%{org: ctx.org, version_id: doc.version_id, atom_ids: doc.atom_ids},
          max_questions_per_call: 1
        )

      assert {:ok, summary} = Evidence.adjudicate(opts)

      # Three candidates, cap 1: three instrument calls, three observations,
      # every candidate judged exactly once.
      assert FakeReqLLM.calls() == 3
      assert length(summary.observation_ids) == 3

      assert [packet] = packets()
      assert Enum.sort(packet.candidate_atom_ids) == Enum.sort(doc.atom_ids)
      assert map_size(packet.candidate_observations) == 3
    end

    @tag :evidence_shape_a
    test "a citation outside the packet refuses the batch — the run fails closed",
         ctx do
      a1 = hd(ctx.atom_ids)

      FakeReqLLM.queue_replies([
        %{
          "choice" => "supports",
          "probabilities" => %{"supports" => 0.9},
          "confidence" => 0.9,
          "source_ids" => [a1, "ghost-atom"]
        }
      ])

      assert {:error, {:citation_outside_packet, ["ghost-atom"]}} =
               Evidence.adjudicate(shape_a_opts(ctx))

      # A failed run is still a recorded run: the evaluation row starts
      # with the loop's bookkeeping and closes :failed; the refused batch's
      # evidence never reaches a packet or an assertion.
      assert [%{status: :failed}] = evaluations()
      assert packets() == []
      assert assertion_rows() == []
    end

    @tag :evidence_shape_a
    test "insufficient expands one retrieval step and records it (ids only)", ctx do
      # The retrieval budget is pinned to one candidate per framing for this
      # test: round 0 surfaces a1 (the seq tie-break), whose reply is
      # insufficient. The growth framing widens the hypotheses AND doubles
      # k — which is how a2 (also about the penalties, framed the other
      # way) surfaces — and its reply is supporting, so the aggregate
      # recovers.
      Application.put_env(:ash_enterprise, :system_one_evidence,
        max_questions_per_call: 5,
        max_expansion_steps: 1,
        retrieval_k: 1
      )

      on_exit(fn -> Application.delete_env(:ash_enterprise, :system_one_evidence) end)

      doc =
        evidence_document([
          "The contract imposes termination penalties for late delivery.",
          "Penalties for termination are waived where notice is given."
        ])

      [a1, a2] = doc.atom_ids

      FakeReqLLM.queue_replies([
        fixture_reply("evidence-insufficient.json"),
        fixture_reply("evidence-supports.json", atom_id: a2)
      ])

      opts =
        shape_a_opts(%{org: ctx.org, version_id: doc.version_id, atom_ids: doc.atom_ids},
          claim: "termination penalties"
        )

      assert {:ok, summary} = Evidence.adjudicate(opts)

      # The composed marginals: insufficient-heavy + supports-heavy.
      assert summary.disposition == :supports

      # One expansion step, recorded as ids: the persisted proof, the
      # observations it produced.
      assert [%{step: 1, candidate_set_id: step_set_id, observation_ids: step_obs}] =
               summary.expansion_steps

      assert step_set_id == summary.candidate_set_ids |> List.last()
      assert length(step_obs) == 1

      assert [evaluation] = evaluations()
      assert evaluation.expansion_steps == summary.expansion_steps
      assert evaluation.candidate_set_ids == summary.candidate_set_ids
      # Initial retrieval + one expansion step.
      assert length(summary.candidate_set_ids) == 2

      assert [packet] = packets()
      assert packet.requires_expansion == false
      assert map_size(packet.candidate_observations) == 2
      assert packet.candidate_atom_ids |> Enum.sort() == Enum.sort([a1, a2])
    end

    @tag :evidence_shape_a
    test "budget exhausted with a still-insufficient aggregate reports requires_expansion",
         ctx do
      FakeReqLLM.queue_replies([
        fixture_reply("evidence-insufficient.json"),
        fixture_reply("evidence-insufficient.json")
      ])

      assert {:ok, summary} = Evidence.adjudicate(shape_a_opts(ctx, max_expansion_steps: 1))

      # The growth step ran and surfaced nothing the first pass had not
      # (one candidate total) — a spent step — so the loop stopped, and
      # the thinness is reported, never hidden.
      assert summary.disposition == :insufficient
      assert [packet] = packets()
      assert packet.requires_expansion == true

      # The assertion still records what the evidence said — the aggregate
      # disposition is insufficient, which is an honest verdict.
      assert summary.assertion.disposition == :insufficient
    end
  end

  ## Call shape B — whole document

  describe "call shape B (whole document)" do
    @tag :evidence_shape_b
    test "tagged localisation plus existence: the packet joins both observations", ctx do
      [a1, a2] = ctx.atom_ids

      FakeReqLLM.queue_replies([
        fixture_reply("choice-localisation.json"),
        fixture_reply("noul-exists.json")
      ])

      regions = %{:preamble => [a1], :obligations => [a2]}

      assert {:ok, summary} = Evidence.adjudicate(shape_b_opts(ctx, regions: regions))

      # The existence answer composes deterministically: p = 0.93 → supports.
      assert summary.disposition == :supports
      assert summary.evaluation.call_shape == :whole_document

      # Two judged questions, two ledger rows: the Choice and the Noul.
      rows =
        Judgment
        |> Ash.Query.filter(id in ^summary.observation_ids)
        |> Ash.read!(authorize?: false)

      assert %{choice: [choice_row], noul: [noul_row]} =
               Enum.group_by(rows, & &1.answer_kind)

      # No retrieval ran: the whole document was the state, so the packet
      # cites no candidate set and carries every atom of the version.
      assert summary.candidate_set_ids == []
      assert summary.evaluation.candidate_set_ids == []

      assert [packet] = packets()
      assert packet.candidate_atom_ids |> Enum.sort() == Enum.sort(ctx.atom_ids)
      # The localisation NAMED the obligations atoms: they ride the Choice
      # observation; the rest ride the existence observation.
      assert packet.selected_atom_ids == [a2]

      assert packet.candidate_observations[a2]["observation_id"] ==
               choice_row.id

      refute packet.candidate_observations[a1]["observation_id"] == choice_row.id
      assert packet.candidate_observations[a1]["observation_id"] == noul_row.id
      assert packet.requires_expansion == false

      # The assertion composes the existence answer into the evidence
      # vocabulary.
      assert summary.assertion.disposition == :supports
      assert Decimal.eq?(Decimal.new(summary.assertion.distribution["supports"]), "0.93")
    end
  end

  ## The proof-growth bookkeeping and identity

  describe "identity and the question set" do
    @tag :evidence_identity
    test "the question set hash moves with the call shape and the questions", ctx do
      shape_a = Evidence.question_set_hash(shape_a_opts(ctx))
      assert shape_a == Evidence.question_set_hash(shape_a_opts(ctx))

      shape_b = Evidence.question_set_hash(shape_b_opts(ctx))
      refute shape_a == shape_b

      other_question =
        Evidence.question_set_hash(shape_a_opts(ctx, question: :document_contains))

      refute shape_a == other_question
    end
  end

  ## AC-2 — the assertion create is inputs-only

  describe "AC-2: AshEvents replay of an assertion-creating run" do
    @tag :evidence_ac2
    test "replay rebuilds the assertion byte-identically with zero model calls", ctx do
      [a1, a2] = ctx.atom_ids

      FakeReqLLM.queue_replies([
        fixture_reply("evidence-supports.json", atom_id: a1),
        fixture_reply("evidence-supports.json", atom_id: a2)
      ])

      assert {:ok, summary} = Evidence.adjudicate(shape_a_opts(ctx))
      assert %EvidenceAssertion{} = original = summary.assertion

      # The audit event AshEvents wrote for the create.
      [event] =
        EventLog
        |> Ash.Query.filter(resource == ^EvidenceAssertion and action == ^:record)
        |> Ash.read!(authorize?: false)

      assert event.record_id == original.id

      # Snapshot the row, wipe it, and replay the recorded event through
      # the AshEvents replay path.
      before = assertion_snapshot(original)

      AshEnterprise.Repo.query!("DELETE FROM system_one_evidence_assertions")
      assert assertion_rows() == []

      FakeReqLLM.reset_calls()
      replay_create_event!(event)

      assert [rebuilt] = assertion_rows()

      # BYTE-IDENTICAL: every field of the record contract, including the
      # database-generated `created_at` (restored from the event) and the
      # derived `record_hash`.
      assert assertion_snapshot(rebuilt) == before

      # The rebuilt row still verifies against its own inputs.
      assert Assertions.record_hash(%{
               id: rebuilt.id,
               record_version: rebuilt.record_version,
               packet_id: rebuilt.packet_id,
               evaluation_id: rebuilt.evaluation_id,
               disposition: rebuilt.disposition,
               distribution: rebuilt.distribution,
               aggregation_rule_version: rebuilt.aggregation_rule_version,
               observation_ids: rebuilt.observation_ids,
               subject: rebuilt.subject,
               predicate: rebuilt.predicate,
               subject_state_digest: rebuilt.subject_state_digest,
               question_set_hash: rebuilt.question_set_hash
             }) == rebuilt.record_hash

      # ZERO model calls: the replay consulted nothing.
      assert FakeReqLLM.calls() == 0

      # And the replay recorded no NEW event — it re-ran the recorded one.
      events_after =
        EventLog
        |> Ash.Query.filter(resource == ^EvidenceAssertion and action == ^:record)
        |> Ash.read!(authorize?: false)

      assert length(events_after) == 1
      assert hd(events_after).id == event.id
    end
  end

  ## The service-task placement

  describe "runs as a service task" do
    @tag :evidence_worker
    test "open_adjudication enqueues the worker; the run records its own evaluation", ctx do
      # The worker reads its wiring from application config, never from job
      # args — the test points it at the fake and at the declared questions
      # the same way a deployment would point it at its own lane.
      Application.put_env(:ash_enterprise, :system_one_evidence_worker,
        judgments: %{req_llm: FakeReqLLM},
        resource: @resource,
        question: :packet_supports
      )

      on_exit(fn ->
        Application.delete_env(:ash_enterprise, :system_one_evidence_worker)
      end)

      FakeReqLLM.queue_replies([
        fixture_reply("evidence-supports.json", atom_id: Enum.at(ctx.atom_ids, 0)),
        fixture_reply("evidence-supports.json", atom_id: Enum.at(ctx.atom_ids, 1))
      ])

      assert {:ok, %{job: job}} = Evidence.open_adjudication(shape_a_opts(ctx))

      assert job.queue == "system_one"
      assert job.args["claim"] == "synthetic"
      assert job.args["tenant"] == ctx.org
      # No evaluation row exists yet: the run creates it with the loop's
      # bookkeeping.
      assert evaluations() == []

      # Draining the queue runs the real pipeline (the fake answers). A
      # failure surfaces the job's recorded errors, not a bare tally.
      drain = Oban.drain_queue(queue: :system_one, with_scheduled: true)

      if drain[:failure] != 0 do
        job = AshEnterprise.Repo.get!(Oban.Job, job.id)
        flunk("worker failed: " <> inspect(job.errors, limit: 30))
      end

      assert %{success: 1, failure: 0} = drain

      assert [evaluated] = evaluations()
      assert evaluated.status == :ok
      assert [_packet] = packets()
      assert [_assertion] = assertion_rows()
    end
  end

  ## The instrument contract — excluded from ordinary runs

  describe "instrument contract (local Ollaya, --only instrument_contract)" do
    @tag :instrument_contract
    test "shape A runs against the reachable local instrument", ctx do
      # No queued replies: the REAL ReqLLM (the capturing default wrapper)
      # calls the local Ollaya profile end to end. Skipped unless the
      # instrument is reachable — the family's dual contract-test posture.
      unless System.get_env("OLLAYA_BASE_URL") && System.get_env("OLLAYA_REACHABLE") do
        refute true, "set OLLAYA_BASE_URL and OLLAYA_REACHABLE=1 to run the contract test"
      end

      opts =
        Keyword.merge(shape_a_opts(ctx), judgments: %{})

      assert {:ok, summary} = Evidence.adjudicate(opts)
      assert summary.evaluation.status == :ok
      assert length(summary.observation_ids) == length(ctx.atom_ids)
    end
  end

  ## The AC-2 replay helper — the AshEvents create path, verbatim
  ##
  ## This is `AshEvents.EventLog.Actions.Replay`'s `handle_action/1`
  ## `:create` branch (prepare_replay_input + prepare_replay_context +
  ## a create under the `ash_events_replay?` context), scoped to the
  ## assertion's own recorded events. The event log's own `:replay` action
  ## is a whole-log operation — its configured `clear_records_for_replay`
  ## is a deployment-level truncate this host has (deliberately) not
  ## authorised — so the proof replays exactly the events under test
  ## through exactly the same mechanism.

  defp replay_create_event!(event) do
    Code.ensure_compiled(EvidenceAssertion)

    changed = event.changed_attributes || %{}

    # Replay's backward-compat step: the primary key rides changed
    # attributes (string-keyed) when the event carries none.
    changed =
      if Map.has_key?(changed, "id") or Map.has_key?(changed, :id) do
        changed
      else
        Map.put(changed, "id", event.record_id)
      end

    context = %{
      ash_events_replay?: true,
      changed_attributes: changed
    }

    tenant = event.metadata["organization_id"]

    EvidenceAssertion
    |> Ash.Changeset.for_create(:record, event.data || %{},
      context: context,
      authorize?: false,
      tenant: tenant
    )
    |> Ash.create!()
  end

  # The record contract, as a plain comparable map — the fragment's own
  # fields, including the one database-generated timestamp. (The platform
  # provenance columns are host metadata around the record, not the record;
  # `record_hash` pins everything the assertion IS.)
  defp assertion_snapshot(row) do
    %{
      id: row.id,
      created_at: row.created_at,
      record_version: row.record_version,
      record_hash: row.record_hash,
      packet_id: row.packet_id,
      evaluation_id: row.evaluation_id,
      disposition: row.disposition,
      distribution: row.distribution,
      aggregation_rule_version: row.aggregation_rule_version,
      observation_ids: row.observation_ids,
      subject: row.subject,
      predicate: row.predicate,
      subject_state_digest: row.subject_state_digest,
      question_set_hash: row.question_set_hash
    }
  end
end

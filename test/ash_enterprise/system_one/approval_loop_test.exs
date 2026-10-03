defmodule AshEnterprise.SystemOne.ApprovalLoopTest do
  @moduledoc """
  S1-62, the quick approval loop's host wiring: the review queue across
  its four kinds, the live accumulation (verdicts land as calibration
  samples per the §7.3 basis routing), the n-threshold trigger surfacing
  into the queue, the activation flow end to end (certify → verify →
  publish → the banding resolver picks the earned table up), and the
  confidence ramp's read surface. Data only — the UI lane renders later.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.BandTablePublication
  alias AshEnterprise.SystemOne.Calibration
  alias AshEnterprise.SystemOne.CalibrationRun
  alias AshEnterprise.SystemOne.CalibrationSample
  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.HumanVerdict
  alias AshEnterprise.SystemOne.ReviewQueue
  alias AshEnterprise.SystemOne.TestSupport.Standard
  alias AshJudgments.Registry.Info

  @family "standards_commits"
  @question Info.question(Standard, :commit_message_imperative)
  @key "judgments_band_standards_commits"
  @fixtures_dir Path.expand("../fixtures/system_one/policy", __DIR__)

  setup do
    Correlation.start_new()

    # The family's policy data, shrunk for tests (law 5: config, not code).
    Application.put_env(:ash_judgments, :families, %{
      @family => %{min_n: 2, min_n_per_class: nil, alpha: 0.016, max_age_days: 90}
    })

    on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)

    %{org: Ash.UUID.generate(), person: person()}
  end

  defp run_attrs(overrides \\ []) do
    Keyword.merge(
      [
        family: @family,
        question_hashes: [@question.question_hash],
        model_version: "winnow:e4b",
        model_digest: "sha256:" <> String.duplicate("b", 64),
        runtime_version: "0.9.0",
        eval_set_hash: "sha256:" <> String.duplicate("c", 64),
        region: "ca",
        n: 2,
        n_per_class: %{},
        metrics: %{"accuracy" => "0.92"},
        ece: "0.03",
        brier: "0.08",
        conformal_thresholds: %{
          "0.016" => %{"threshold" => "0.98", "cost" => %{"false_admit" => "1.0"}}
        },
        source: :eval_set,
        created_by: "calibration-harness",
        observations_digest: "sha256:" <> String.duplicate("d", 64),
        pass_bar: %{"accuracy" => "0.9"},
        finished_at: DateTime.utc_now()
      ],
      overrides
    )
  end

  defp record_run!(ctx, overrides \\ []) do
    {:ok, run, outcome} =
      Calibration.record_run(run_attrs(overrides),
        actor: SystemActor.process(),
        tenant: ctx.org
      )

    {run, outcome}
  end

  defp certify!(ctx, run, definition_key \\ @key) do
    BandTableCertification
    |> Ash.Changeset.for_create(
      :record,
      %{
        definition_key: definition_key,
        definition_version: "1",
        content_hash: "sha256:" <> String.duplicate("a", 64),
        family: @family,
        calibration_run_id: run.id,
        verification: %{"optimise_split_disjoint" => true},
        certified_by: to_string(ctx.person.email)
      },
      actor: ctx.person,
      tenant: ctx.org
    )
    |> Ash.create!()
  end

  defp queue_kinds(ctx, kind, opts \\ []) do
    # The system view: queue reads without an actor run unauthorised.
    # A person's view narrows through each resource's RoleGrant read
    # policy (asserted where a grant exists); content assertions here are
    # about QUEUE MEMBERSHIP, which tenancy already scopes.
    {:ok, %{items: items}} = ReviewQueue.pending(opts)

    items |> Enum.filter(&(&1.kind == kind)) |> Enum.map(& &1.id)
  end

  # --- the trigger and the queue -----------------------------------------------

  describe "the n-threshold trigger surfaces into the queue" do
    test "a qualifying run proposes, and the queue awaits a certification", ctx do
      {run, outcome} = record_run!(ctx)

      assert match?({:proposed, %{}}, outcome)
      assert run.result == :proposed_table
      assert run.proposed_band_table["definition_key"] == @key
      assert run.proposed_band_table["thresholds"]["threshold"] == "0.98"
      assert run.proposed_band_table["family_tag"] == "judgments:family:#{@family}"

      assert queue_kinds(ctx, :band_table_proposal) == [run.id]

      # A person certifies; the item leaves the queue.
      certify!(ctx, run)
      refute run.id in queue_kinds(ctx, :band_table_proposal)
    end

    test "a run below the family's min_n is recorded as no_table and never surfaces", ctx do
      {run, {:refused, findings}} = record_run!(ctx, n: 1)

      assert run.result == :no_table
      assert run.proposed_band_table == nil
      assert [%{finding: :n_below_min, required_n: 2, actual_n: 1}] = findings
      assert queue_kinds(ctx, :band_table_proposal) == []
    end

    test "a run that misses its own pre-registered pass bar proposes nothing", ctx do
      {run, {:refused, findings}} = record_run!(ctx, metrics: %{"accuracy" => "0.5"})

      assert run.result == :no_table
      assert [%{finding: :metrics_miss_pass_bar, missed: %{"accuracy" => "0.9"}}] = findings
    end
  end

  # --- the live accumulation -----------------------------------------------------

  describe "the live accumulation (verdicts land as samples)" do
    test "a labelling verdict appends one pair to the family's slot", ctx do
      judgment = record!(tenant: ctx.org)

      _verdict =
        HumanVerdict
        |> Ash.Changeset.for_create(
          :record,
          %{
            judgment_id: judgment.id,
            question_hash: judgment.question_hash,
            model_answer: %{"kind" => "noul", "value" => nil, "distribution" => %{}},
            human_value: "true",
            reviewer: to_string(ctx.person.email),
            basis: :labelling
          },
          actor: ctx.person,
          tenant: ctx.org
        )
        |> Ash.create!()

      assert [sample] =
               CalibrationSample
               |> Ash.Query.filter(observation_id == ^judgment.id)
               |> Ash.read!(authorize?: false)

      # The slot fields ride the judgment (the run key minus the eval set).
      assert sample.family == judgment.family
      assert sample.question_hash == judgment.question_hash
      assert sample.model_digest == judgment.model_digest
      assert sample.runtime_version == judgment.runtime_version
      assert sample.region == judgment.region
      assert sample.pair_digest =~ ~r/^sha256:[0-9a-f]{64}$/
      refute is_nil(sample.gold_label_digest)
    end

    test "review_task and audit_sample feed the slot; an override does not", ctx do
      # The slot identity pins one row per (observation, question, model,
      # region): the two feeding bases land on DIFFERENT observations.
      for basis <- [:review_task, :audit_sample] do
        judgment = record!(tenant: ctx.org)

        _verdict =
          HumanVerdict
          |> Ash.Changeset.for_create(
            :record,
            %{
              judgment_id: judgment.id,
              question_hash: judgment.question_hash,
              model_answer: %{"kind" => "noul"},
              human_value: "true",
              reviewer: to_string(ctx.person.email),
              basis: basis
            },
            actor: ctx.person,
            tenant: ctx.org
          )
          |> Ash.create!()
      end

      assert length(CalibrationSample |> Ash.read!(authorize?: false)) == 2

      judgment = record!(tenant: ctx.org)

      _override =
        HumanVerdict
        |> Ash.Changeset.for_create(
          :record,
          %{
            judgment_id: judgment.id,
            question_hash: judgment.question_hash,
            model_answer: %{"kind" => "noul"},
            human_value: "false",
            reviewer: to_string(ctx.person.email),
            basis: :override
          },
          actor: ctx.person,
          tenant: ctx.org
        )
        |> Ash.create!()

      # The override is a correction, not a label: no row for it.
      assert length(CalibrationSample |> Ash.read!(authorize?: false)) == 2
    end
  end

  # --- the review band in the queue ----------------------------------------------

  describe "review-band judgments await verdicts" do
    test "a review banding enters the queue and leaves when the verdict lands", ctx do
      judgment = record!(tenant: ctx.org)

      resolver = fn _family, _tenant, _inputs ->
        {:ok,
         %{
           band_table: %{
             "definition_key" => "stub",
             "definition_version" => "1",
             "content_hash" => "sha256:" <> String.duplicate("e", 64),
             "definition_id" => Ash.UUID.generate(),
             "tenant_fork" => nil
           },
           outputs: %{"band" => "review", "reason_code" => "borderline"},
           matched_rule_ids: ["Rule_review"],
           decision_evaluation_id: Ash.UUID.generate()
         }}
      end

      assert {:ok, %{banding: banding, band: :review}} =
               Step.band(
                 [
                   %{
                     question: @question,
                     answer: %{value: "imperative"},
                     observation_id: judgment.id
                   }
                 ],
                 family: @family,
                 tenant: ctx.org,
                 subject: %{"type" => "commit", "id" => "commit-1"},
                 predicate: @question.question_id,
                 resolver: resolver
               )

      assert queue_kinds(ctx, :review_band) == [banding.id]

      # The person's verdict (a review_task basis — it also feeds the slot)
      # empties the queue item.
      _ =
        HumanVerdict
        |> Ash.Changeset.for_create(
          :record,
          %{
            judgment_id: judgment.id,
            question_hash: judgment.question_hash,
            model_answer: %{"kind" => "choice", "value" => "imperative"},
            human_value: "other",
            reviewer: to_string(ctx.person.email),
            basis: :review_task
          },
          actor: ctx.person,
          tenant: ctx.org
        )
        |> Ash.create!()

      refute banding.id in queue_kinds(ctx, :review_band)
    end
  end

  # --- activation end to end -----------------------------------------------------

  @band_dmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
               xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
               xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
               id="band_standards_commits_definitions"
               name="Commit message band"
               namespace="https://ash-enterprise.example/dmn/band-standards-commits"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_value" name="commit_message_imperative__value">
      <variable id="var_value" name="commit_message_imperative__value" typeRef="string"/>
    </inputData>

    <decision id="decision_band" name="Band">
      <variable id="var_band" name="Band" typeRef="string"/>
      <informationRequirement id="req_value">
        <requiredInput href="#input_value"/>
      </informationRequirement>
      <decisionTable id="table_band" hitPolicy="UNIQUE">
        <input id="clause_value">
          <inputExpression id="expr_value" typeRef="string"><text>commit_message_imperative__value</text></inputExpression>
        </input>
        <output id="out_band" name="band" typeRef="string"/>
        <rule id="rule_earned_admit"><inputEntry id="ie_admit"><text>"imperative"</text></inputEntry><outputEntry id="oe_band_admit"><text>"admit"</text></outputEntry></rule>
        <rule id="rule_earned_review"><inputEntry id="ie_review"><text>not("imperative")</text></inputEntry><outputEntry id="oe_band_review"><text>"review"</text></outputEntry></rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  describe "activation end to end (certify → verify → publish → the resolver sees it)" do
    test "the earned table publishes and the banding step bands through it", ctx do
      # A band table is a PLATFORM baseline: the resolver resolves it in
      # the platform organization (tenants fork or rebind above it).
      platform = AshEnterprise.Platform.Seeder.seed_platform_organization()
      AshEnterprise.Process.Resolver.forget_platform_tenant()

      # The draft definition is saved first (the harness renders the
      # proposal's DMN — S1-25's job — before publication).
      draft =
        Definition.create!(%{key: @key, name: @key, xml: @band_dmn},
          authorize?: false,
          tenant: platform.id
        )

      {run, _outcome} = record_run!(ctx)
      certification = certify!(ctx, run)

      ref = %{
        family: @family,
        model_digest: run.model_digest,
        runtime_version: run.runtime_version,
        region: "ca"
      }

      # Refusal path: the verifier runs BEFORE any publish — no
      # certification, no publish.
      assert {:error, {:not_verified, findings}} =
               BandTablePublication.publish(ref, nil, run, actor: ctx.person, tenant: ctx.org)

      assert Enum.any?(findings, &(&1.finding == :not_certified))

      # The person's gate is the CERTIFICATION (person-only resource);
      # the lifecycle publish is machinery executing that verified
      # decision, so it runs as the system actor.
      assert {:ok, published} =
               BandTablePublication.publish(
                 ref,
                 certification,
                 run,
                 actor: SystemActor.process(),
                 tenant: platform.id
               )

      assert published.status == :published
      refute published.id in queue_kinds(ctx, :band_table_proposal)

      # The banding step's resolver (default, no stub) now bands through
      # the earned table — matched_rule_ids populated from the recorded
      # Evaluation, the earned reason_code riding the row.
      judgment = record!(tenant: ctx.org)

      assert {:ok, %{banding: banding, band: :admit, materialisation: :materialised}} =
               Step.band(
                 [
                   %{
                     question: @question,
                     answer: %{
                       value: "imperative",
                       probabilities: %{
                         imperative: Decimal.new("0.9"),
                         other: Decimal.new("0.08"),
                         insufficient: Decimal.new("0.02")
                       },
                       confidence: Decimal.new("0.9")
                     },
                     observation_id: judgment.id
                   }
                 ],
                 family: @family,
                 tenant: ctx.org,
                 subject: %{"type" => "commit", "id" => "commit-1"},
                 predicate: @question.question_id,
                 holds_value: "imperative"
               )

      assert banding.matched_rule_ids == ["rule_earned_admit"]
      # boxic v0 band tables are single-output (the band): the step derives
      # fact_value from the gated answer and reason_code from band+version.
      assert banding.reason_code == "band_admit_v#{published.version}"
      assert banding.band_table["definition_key"] == @key
      assert banding.fact_value == "imperative"

      assert [fact] = Fact |> Ash.read!(authorize?: false)
      assert fact.value == "imperative"
      assert fact.holds == true
    end
  end

  # --- the confidence ramp ---------------------------------------------------------

  describe "the confidence ramp" do
    test "lists the family's runs in order with thresholds, and the current certification", ctx do
      {run_one, _} = record_run!(ctx)
      {run_two, _} = record_run!(ctx, n: 5, ece: "0.05")
      certification = certify!(ctx, run_two)

      {:ok, ramp} = Calibration.ramp(@family)

      assert ramp.family == @family
      assert ramp.alpha == "0.016"
      assert length(ramp.points) == 2
      assert Enum.map(ramp.points, & &1.n) == [2, 5]
      assert Enum.all?(ramp.points, &(&1.conformal_threshold == "0.98"))
      assert Enum.map(ramp.points, & &1.ece) == ["0.03", "0.05"]

      assert ramp.current.certified_by == to_string(ctx.person.email)
      assert certification.certified_at == ramp.current.certified_at
      assert run_two.id == certification.calibration_run_id
    end
  end

  # --- attribution (AC-4, the ledger's pattern) -------------------------------------

  describe "attribution" do
    test "a calibration run's event carries tenant and correlation" do
      org = Ash.UUID.generate()
      correlation_id = Ash.UUID.generate()

      run =
        Correlation.with_correlation(correlation_id, fn ->
          {run, _} = record_run!(%{org: org})
          run
        end)

      [event] =
        EventLog
        |> Ash.Query.filter(resource == ^CalibrationRun and record_id == ^run.id)
        |> Ash.read!(authorize?: false)

      assert event.metadata["correlation_id"] == correlation_id
      assert event.organization_id == org
      assert event.user_id == nil
    end

    test "a calibration sample's event carries tenant and correlation", ctx do
      judgment = record!(tenant: ctx.org)
      correlation_id = Ash.UUID.generate()

      Correlation.with_correlation(correlation_id, fn ->
        _ =
          HumanVerdict
          |> Ash.Changeset.for_create(
            :record,
            %{
              judgment_id: judgment.id,
              question_hash: judgment.question_hash,
              model_answer: %{"kind" => "noul"},
              human_value: "true",
              reviewer: to_string(ctx.person.email),
              basis: :labelling
            },
            actor: ctx.person,
            tenant: ctx.org
          )
          |> Ash.create!()
      end)

      [sample] =
        CalibrationSample
        |> Ash.Query.filter(observation_id == ^judgment.id)
        |> Ash.read!(authorize?: false)

      [event] =
        EventLog
        |> Ash.Query.filter(resource == ^CalibrationSample and record_id == ^sample.id)
        |> Ash.read!(authorize?: false)

      assert event.metadata["correlation_id"] == correlation_id
      assert event.organization_id == ctx.org
    end
  end
end

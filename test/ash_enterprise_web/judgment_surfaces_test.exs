defmodule AshEnterpriseWeb.JudgmentSurfacesTest do
  @moduledoc """
  The judgment surfaces (ADR 0061): ash_judgments' surfaces bound to this
  application's System One resources, served under `/app/judgments`. A
  person settles the loop's work from them: a verdict on a review-banded
  judgment, and the certification and publication of an earned band table,
  each clicked through `AshA2ui.ActionHandler` as that person.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Standards.Questions
  alias AshEnterprise.SystemOne.Banding
  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.Calibration
  alias AshEnterprise.SystemOne.CalibrationRun
  alias AshEnterprise.SystemOne.HumanVerdict
  alias AshEnterpriseWeb.A2ui.Judgments

  @family "house_style"

  test "the judgment surfaces are declared at their routes, in the Judgments group" do
    surfaces = Enum.filter(AshEnterprise.Surfaces.all(), &(&1.group == :judgments))

    assert Enum.map(surfaces, & &1.path) == [
             "/app/judgments",
             "/app/judgments/band-tables",
             "/app/judgments/certifications",
             "/app/judgments/calibration",
             "/app/judgments/facts"
           ]

    # The acts are person-gated by policy, not by a door.
    assert Enum.all?(surfaces, &(&1.door == :signed_in))
  end

  test "each judgment surface derives valid A2UI messages" do
    for ui <- [
          Judgments.VerdictsUI,
          Judgments.BandTablesUI,
          Judgments.CertificationsUI,
          Judgments.CalibrationUI,
          Judgments.FactsUI
        ] do
      messages = AshA2ui.Info.build_surface(ui)
      assert Enum.any?(messages, &Map.has_key?(&1, "createSurface")), inspect(ui)
    end
  end

  describe "a verdict, from the verdicts surface" do
    setup :tenant

    test "a person's click records their verdict, and the judgment leaves the queue", ctx do
      judgment = record!(tenant: ctx.org)
      banding = review_banding!(judgment, ctx.org)
      assert [banding.id] == awaiting(ctx)

      assert {:ok, _messages} =
               invoke(Judgments.VerdictsUI, "record_verdict", banding, ctx,
                 values: %{"value" => "yes", "reason" => "Reads as a durable fact."}
               )

      assert [verdict] = HumanVerdict |> Ash.read!(tenant: ctx.org, authorize?: false)
      assert verdict.judgment_id == judgment.id
      assert verdict.human_value == "true"
      assert verdict.reviewer == ctx.email
      assert verdict.basis == :review_task
      assert [] == awaiting(ctx)
    end

    test "no system actor records a verdict", ctx do
      banding = review_banding!(record!(tenant: ctx.org), ctx.org)

      assert {:error, %Ash.Error.Forbidden{}} =
               Banding
               |> Ash.ActionInput.for_action(
                 :record_verdict,
                 %{record_id: banding.id, value: "yes"},
                 actor: SystemActor.oban(),
                 tenant: ctx.org
               )
               |> Ash.run_action()
    end
  end

  describe "certify and publish, from the band-table surface" do
    setup :tenant

    setup do
      Application.put_env(:ash_judgments, :families, %{
        @family => %{min_n: 2, min_n_per_class: nil, alpha: 0.016, max_age_days: 90}
      })

      on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)
    end

    test "a person's click certifies the earned table as them and publishes it", ctx do
      run = proposed_run!(ctx.org)
      assert [run.id] == awaiting_certification(ctx)

      assert {:ok, _messages} = invoke(Judgments.BandTablesUI, "certify_and_publish", run, ctx)

      assert [certification] =
               BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)

      assert certification.calibration_run_id == run.id
      assert certification.certified_by == ctx.email

      assert %{status: :published, version: 1} = definition(@family)
      assert [] == awaiting_certification(ctx)
    end

    test "a refusal leaves no certification behind, and the run stays in the queue", ctx do
      run = proposed_run!(ctx.org)
      platform = Seeder.seed_platform_organization()
      key = Resolver.band_table_key(@family)

      Definition.create!(%{key: key, name: key, xml: rendered(run)},
        authorize?: false,
        tenant: platform.id
      )

      assert {:error, error} =
               CalibrationRun
               |> Ash.ActionInput.for_action(:certify_and_publish, %{record_id: run.id},
                 actor: ctx.actor,
                 tenant: ctx.org
               )
               |> Ash.run_action()

      assert Exception.message(error) =~ "unpublished draft"
      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
      assert [run.id] == awaiting_certification(ctx)
    end

    test "the run's table gates on the questions it calibrated", ctx do
      run = proposed_run!(ctx.org)

      assert AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish.score_inputs(run) ==
               ["hs1_lead_with_outcome_or_ask__p_true", "hs5_promise_only_agreed_to__p_true"]
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp tenant(_ctx) do
    Correlation.start_new()
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)
    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(name: "Judgments #{n}", unique_name: "judgments-#{n}")

    %{
      org: organization.id,
      email: to_string(admin.email),
      actor: ActorContext.attach(admin, ActorContext.build(admin, tenant: organization.id))
    }
  end

  defp invoke(ui, action, record, ctx, opts \\ []) do
    context =
      %{"action" => action, "recordId" => record.id, "component" => "table"}
      |> then(&if(opts[:values], do: Map.put(&1, "values", opts[:values]), else: &1))

    AshA2ui.ActionHandler.handle(ui, %{"name" => "invoke", "context" => context},
      actor: ctx.actor,
      tenant: ctx.org
    )
  end

  defp awaiting(ctx) do
    Banding
    |> Ash.Query.for_read(:awaiting_verdict, %{}, actor: ctx.actor, tenant: ctx.org)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp awaiting_certification(ctx) do
    CalibrationRun
    |> Ash.Query.for_read(:awaiting_certification, %{}, actor: ctx.actor, tenant: ctx.org)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp review_banding!(judgment, org) do
    Banding
    |> Ash.Changeset.for_create(
      :record,
      %{
        observation_ids: [judgment.id],
        band: :review,
        reason_code: "below_conformal_threshold",
        matched_rule_ids: ["rule_review"],
        band_table: %{
          "definition_key" => "judgments_band_system_one_notes",
          "definition_version" => "1"
        },
        decision_evaluation_id: Ash.UUID.generate(),
        inputs: %{
          "family" => "system_one_notes",
          "notes_follow_up__present" => "true",
          "notes_follow_up__p_true" => "0.9"
        },
        mode: :live
      },
      actor: SystemActor.process(),
      tenant: org
    )
    |> Ash.create!()
  end

  defp proposed_run!(org) do
    hashes =
      Enum.map(
        [:hs1_lead_with_outcome_or_ask, :hs5_promise_only_agreed_to],
        &Questions.declared(&1).question_hash
      )

    {:ok, run, {:proposed, _proposal}} =
      Calibration.record_run(
        %{
          family: @family,
          question_hashes: hashes,
          model_version: "winnow:e4b",
          model_digest: "sha256:" <> String.duplicate("b", 64),
          runtime_version: "ollaya-0.9.0",
          eval_set_hash: "sha256:" <> String.duplicate("c", 64),
          region: "ca",
          n: 2,
          n_per_class: %{},
          metrics: %{},
          ece: "0.03",
          brier: "0.08",
          conformal_thresholds: %{"0.016" => %{"threshold" => "0.9"}},
          source: :eval_set,
          created_by: "calibration-harness",
          observations_digest: "sha256:" <> String.duplicate("d", 64),
          pass_bar: %{},
          finished_at: DateTime.utc_now()
        },
        actor: SystemActor.process(),
        tenant: org
      )

    run
  end

  defp rendered(run) do
    {:ok, xml} =
      AshJudgments.Calibration.ProposalDmn.render(run.proposed_band_table,
        score_input:
          AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish.score_inputs(run)
      )

    xml
  end

  defp definition(family) do
    platform = Seeder.seed_platform_organization()
    key = Resolver.band_table_key(family)

    Definition
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: platform.id)
  end
end

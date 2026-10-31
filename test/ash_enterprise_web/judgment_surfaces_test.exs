defmodule AshEnterpriseWeb.JudgmentSurfacesTest do
  @moduledoc """
  The judgment surfaces (ADR 0061): ash_judgments' surfaces bound to this
  application's System One resources, served under `/app/judgments`. A
  person settles the loop's work from them: a verdict on a review-banded
  judgment, and the certification and publication of an earned band table,
  each clicked through `AshA2ui.ActionHandler` as that person.

  Certifying and revoking are governed targets (ADR 0055, ADR 0061): the button runs
  `certify_now` / `revoke_now`, the person's own request, which they confirm in the same
  click. An agent's request for the same acts (`certify:<run id>`, `revoke:<certification
  id>`) runs only after a person approves it, as that person.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshAgent.Invocation.{Executor, IdempotencyConflict, Ungoverned}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
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
  @certify "AshEnterprise.SystemOne.CalibrationRun.certify_and_publish"
  @revoke "AshEnterprise.SystemOne.BandTableCertification.revoke"

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

      assert {:ok, _messages} = invoke(Judgments.BandTablesUI, "certify_now", run, ctx)

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

      assert {:error, error} = click(CalibrationRun, :certify_now, run, ctx)

      assert Exception.message(error) =~ "unpublished_draft_exists"
      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
      assert [run.id] == awaiting_certification(ctx)
    end

    test "the governed action refuses a direct call, and the click is no way round it", ctx do
      run = proposed_run!(ctx.org)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CalibrationRun
               |> Ash.ActionInput.for_action(:certify_and_publish, %{record_id: run.id},
                 actor: ctx.actor,
                 tenant: ctx.org
               )
               |> Ash.run_action()

      assert [%Ungoverned{reason: :no_invocation}] = errors
      assert [run.id] == awaiting_certification(ctx)
    end

    test "a click records one invocation, approved and run as the person", ctx do
      run = proposed_run!(ctx.org)
      assert {:ok, %{"status" => "succeeded"}} = click(CalibrationRun, :certify_now, run, ctx)

      assert [row] = Execution.list_invocations!(oban(ctx))
      assert row.target == @certify

      assert {row.status, row.approval_mode, row.approved_by_id} ==
               {:succeeded, :confirm, ctx.user.id}

      assert row.executing_principal == %{type: :person, id: ctx.user.id}
    end

    test "a person who may not approve gets the request, waiting, and nothing is certified",
         ctx do
      run = proposed_run!(ctx.org)
      outsider = outsider!(ctx)

      assert {:ok, %{"status" => "awaiting_approval", "approval_url" => url}} =
               click(CalibrationRun, :certify_now, run, ctx, outsider)

      assert url =~ "/app/r/approvals/"
      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
    end
  end

  describe "an agent's request to certify" do
    setup :tenant

    setup do
      Application.put_env(:ash_judgments, :families, %{
        @family => %{min_n: 2, min_n_per_class: nil, alpha: 0.016, max_age_days: 90}
      })

      on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)
    end

    test "is refused without an approval, and runs once a person approves it", ctx do
      run = proposed_run!(ctx.org)
      row = request!(ctx, run)
      assert {row.status, row.approval_mode} == {:awaiting_approval, :confirm}
      assert row.effects["approver_role"] == "administrator"

      # Nothing is ready, so nothing runs; the table is still waiting.
      assert {:ok, :skipped} = Executor.execute(Execution.Invocation, row.id, oban(ctx))
      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
      assert [run.id] == awaiting_certification(ctx)

      approve!(row, ctx.actor, ctx)
      assert %{status: :ready} = ready = Execution.apply_invocation_decision!(row, oban(ctx))
      assert {:ok, :succeeded} = Executor.execute(Execution.Invocation, ready.id, oban(ctx))

      assert Execution.get_invocation!(row.id, oban(ctx)).status == :succeeded

      assert [certification] =
               BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)

      assert certification.calibration_run_id == run.id
      assert certification.certified_by == ctx.email
      assert %{status: :published} = definition(@family)
      assert [] == awaiting_certification(ctx)
    end

    test "is rejected by the person, and certifies nothing", ctx do
      run = proposed_run!(ctx.org)
      row = request!(ctx, run)
      approve!(row, ctx.actor, ctx, :reject)

      assert %{status: :rejected} = Execution.apply_invocation_decision!(row, oban(ctx))
      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
      assert [run.id] == awaiting_certification(ctx)
    end

    test "the same key returns the same row, and another request under it is a conflict", ctx do
      run = proposed_run!(ctx.org)
      other = proposed_run!(ctx.org)
      row = request!(ctx, run)

      assert request!(ctx, run).id == row.id
      assert [_one] = Execution.list_invocations!(oban(ctx))

      assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{key: key}]}} =
               Execution.invoke(@certify, %{"record_id" => other.id}, %{key: "certify:#{run.id}"},
                 actor: ctx.actor,
                 tenant: ctx.org
               )

      assert key == "certify:#{run.id}"
    end

    test "the request action records the same keyed request and returns where it waits", ctx do
      run = proposed_run!(ctx.org)

      assert {:ok, %{"status" => "awaiting_approval", "approval_url" => url} = result} =
               CalibrationRun
               |> Ash.ActionInput.for_action(:request_certification, %{record_id: run.id},
                 actor: ctx.actor,
                 tenant: ctx.org
               )
               |> Ash.run_action()

      assert url =~ "/app/r/approvals/"
      assert result["target"] == @certify
      assert request!(ctx, run).id == result["invocation_id"]
      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
    end

    test "an automation principal's request is denied when it runs: certifying is a person's",
         ctx do
      run = proposed_run!(ctx.org)
      agent = "table-certifier"

      Security.AgentStartGrant.grant!(
        %{agent_key: agent, principal_id: ctx.user.id, principal_type: :user},
        actor: ctx.actor,
        tenant: ctx.org
      )

      actor = AutomationPrincipal.start(ctx.actor, :evidence_admitter, agent)

      row =
        Execution.invoke!(@certify, %{"record_id" => run.id}, %{key: "certify:#{run.id}"},
          actor: actor,
          tenant: ctx.org
        )

      assert row.executing_principal.type == :automation
      approve!(row, ctx.actor, ctx)
      assert %{status: :ready} = ready = Execution.apply_invocation_decision!(row, oban(ctx))
      assert {:ok, :failed} = Executor.execute(Execution.Invocation, ready.id, oban(ctx))

      assert %{status: :failed, failure_class: :denied} =
               Execution.get_invocation!(row.id, oban(ctx))

      assert [] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
    end

    test "a verdict is never an agent's: no request action, no Governed validation", ctx do
      actions = Ash.Resource.Info.actions(Banding)
      refute Enum.any?(actions, &(&1.name in [:request_verdict, :record_verdict_now]))

      refute Enum.any?(
               Ash.Resource.Info.validations(Banding),
               &match?({AshAgent.Validations.Governed, _}, &1.validation)
             )

      banding = review_banding!(record!(tenant: ctx.org), ctx.org)

      # Asked for through an invocation by an automation principal, it is denied and
      # records nothing (AST-136).
      agent = "verdict-writer"

      Security.AgentStartGrant.grant!(
        %{agent_key: agent, principal_id: ctx.user.id, principal_type: :user},
        actor: ctx.actor,
        tenant: ctx.org
      )

      args = %{"record_id" => banding.id, "value" => "yes"}

      case Execution.invoke(
             "AshEnterprise.SystemOne.Banding.record_verdict",
             args,
             %{key: "verdict:#{banding.id}"},
             actor: AutomationPrincipal.start(ctx.actor, :evidence_admitter, agent),
             tenant: ctx.org
           ) do
        {:ok, row} ->
          approve!(row, ctx.actor, ctx)
          ready = Execution.apply_invocation_decision!(row, oban(ctx))
          Executor.execute(Execution.Invocation, ready.id, oban(ctx))
          assert Execution.get_invocation!(row.id, oban(ctx)).status == :failed

        {:error, _refused} ->
          :ok
      end

      assert [] == HumanVerdict |> Ash.read!(tenant: ctx.org, authorize?: false)
    end
  end

  describe "revoke, from the certifications surface" do
    setup :tenant

    setup do
      Application.put_env(:ash_judgments, :families, %{
        @family => %{min_n: 2, min_n_per_class: nil, alpha: 0.016, max_age_days: 90}
      })

      on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)
    end

    defp certified!(ctx) do
      run = proposed_run!(ctx.org)
      {:ok, _} = click(CalibrationRun, :certify_now, run, ctx)
      [certification] = BandTableCertification |> Ash.read!(tenant: ctx.org, authorize?: false)
      certification
    end

    test "a person's click revokes the certification as them", ctx do
      certification = certified!(ctx)

      assert {:ok, _messages} =
               invoke(Judgments.CertificationsUI, "revoke_now", certification, ctx)

      revoked =
        Ash.get!(BandTableCertification, certification.id, tenant: ctx.org, authorize?: false)

      assert {revoked.status, revoked.certified_by} == {:revoked, ctx.email}
    end

    test "the governed revoke refuses a direct call", ctx do
      certification = certified!(ctx)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               certification
               |> Ash.Changeset.for_update(:revoke, %{}, actor: ctx.actor, tenant: ctx.org)
               |> Ash.update()

      assert Enum.any?(errors, &match?(%Ungoverned{reason: :no_invocation}, &1))

      assert Ash.get!(BandTableCertification, certification.id,
               tenant: ctx.org,
               authorize?: false
             ).status == :certified
    end

    test "an agent's request runs once a person approves it, and not before", ctx do
      certification = certified!(ctx)
      key = "revoke:#{certification.id}"

      row =
        Execution.invoke!(@revoke, %{"id" => certification.id}, %{key: key},
          actor: ctx.actor,
          tenant: ctx.org
        )

      assert row.status == :awaiting_approval
      assert {:ok, :skipped} = Executor.execute(Execution.Invocation, row.id, oban(ctx))

      assert Ash.get!(BandTableCertification, certification.id,
               tenant: ctx.org,
               authorize?: false
             ).status == :certified

      approve!(row, ctx.actor, ctx)
      ready = Execution.apply_invocation_decision!(row, oban(ctx))
      assert {:ok, :succeeded} = Executor.execute(Execution.Invocation, ready.id, oban(ctx))

      assert Ash.get!(BandTableCertification, certification.id,
               tenant: ctx.org,
               authorize?: false
             ).status == :revoked

      assert Execution.invoke!(@revoke, %{"id" => certification.id}, %{key: key},
               actor: ctx.actor,
               tenant: ctx.org
             ).id == row.id
    end

    test "the revocation request action keys the request to the certification", ctx do
      certification = certified!(ctx)

      assert {:ok, %{"status" => "awaiting_approval", "target" => @revoke}} =
               BandTableCertification
               |> Ash.ActionInput.for_action(:request_revocation, %{record_id: certification.id},
                 actor: ctx.actor,
                 tenant: ctx.org
               )
               |> Ash.run_action()

      keys = Enum.map(Execution.list_invocations!(oban(ctx)), & &1.invocation_key)
      assert "revoke:#{certification.id}" in keys
    end
  end

  describe "certify and publish, more" do
    setup :tenant

    setup do
      Application.put_env(:ash_judgments, :families, %{
        @family => %{min_n: 2, min_n_per_class: nil, alpha: 0.016, max_age_days: 90}
      })

      on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)
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
      user: admin,
      email: to_string(admin.email),
      actor: ActorContext.attach(admin, ActorContext.build(admin, tenant: organization.id))
    }
  end

  defp oban(ctx), do: [actor: SystemActor.oban(), tenant: ctx.org]

  # A person with no role: not a candidate to approve anything.
  defp outsider!(ctx) do
    AshEnterprise.Test.DailyFixtures.member!(
      %{tenant: ctx.org, user: ctx.user},
      "Reader #{System.unique_integer([:positive])}",
      []
    )
  end

  # The button's own action, as `actor` (default: the tenant's administrator).
  defp click(resource, action, record, ctx, who \\ nil) do
    resource
    |> Ash.ActionInput.for_action(action, %{record_id: record.id},
      actor: (who && who.actor) || ctx.actor,
      tenant: ctx.org
    )
    |> Ash.run_action()
  end

  # What an agent's tool call does for the person it works for.
  defp request!(ctx, run) do
    Execution.invoke!(@certify, %{"record_id" => run.id}, %{key: "certify:#{run.id}"},
      actor: ctx.actor,
      tenant: ctx.org
    )
  end

  # The person deciding the invocation's approval task, through the task door.
  defp approve!(row, actor, ctx, door \\ :approve) do
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(door, %{record_id: task.id}, actor: actor, tenant: ctx.org)
    |> Ash.run_action!()
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

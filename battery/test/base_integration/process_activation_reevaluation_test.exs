defmodule Battery.Integration.ProcessActivationReevaluationTest do
  @moduledoc """
  Scenario 5 — process timer → dated compliance activation → decision
  re-evaluation.

  The seam: an ash_bpmn intermediate timer wakes a process whose service
  task activates an APPROVED ash_compliance rule-set revision with a
  declared `effective_at` (taken from the process subject, never the
  diagram); the next service task re-evaluates every applicant in the
  subject's organization through ash_decisions, each answer derived from
  the revisions IN FORCE at the instant asked about.

  Asserted, in each direction of time:

    * nothing happens before the timer fires — the process, not a
      scheduler inside the compliance plane, is what activates;
    * the re-evaluation covers every applicant in scope and no other, one
      recorded ash_decisions evaluation each, correlated to its applicant;
    * a FUTURE-dated activation leaves today's recorded answers unchanged
      and changes only the answer as of its effective instant;
    * a BACKDATED activation changes today's answers and the as-of answer
      after its instant, while the answer before its instant stands.

  What one dependency proves on its own (period splitting, the
  succession's retire, timer scheduling, the DMN engine) stays in that
  dependency's suite.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshCompliance.Resources.RuleSetRevision
  alias Battery.Bpmn.{Definition, Instance, Invoker}
  alias Battery.Compliance.{Applicant, ScheduledActivation, Standing}

  @rule_set "intake_rules"
  @process "battery_scheduled_activation"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    Enum.each(
      [Battery.Decisions.Evaluation, Battery.Decisions.Definition],
      &Battery.Repo.delete_all(&1)
    )

    for table <- ~w(battery_applicants battery_scheduled_activations
                    bpmn_definitions bpmn_instances bpmn_tokens bpmn_process_events
                    ash_compliance_rule_set_revisions) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    TestJobs.clear()
    Invoker.clear_calls()

    on_exit(fn ->
      TestJobs.clear()
      Invoker.clear_calls()
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    org = Ecto.UUID.generate()
    other_org = Ecto.UUID.generate()

    # ── the decision: publish the standing table ──────────────────────────
    {:ok, standing_definition} =
      Battery.Decisions.Definition.create!(%{
        key: Standing.decision_key(),
        name: "Battery intake standing",
        xml: Battery.Fixtures.intake_standing_dmn()
      })
      |> Battery.Decisions.Definition.publish()

    # ── the compliance plane: revision 1 in force since 60 days ago,
    #    revision 2 approved (not active) since 57 days ago — both landed at
    #    declared instants, so a backdated activation has history to split ──
    land_revision!(org, Battery.Compliance.IntakeRules, "1", days(now, -63),
      activate_at: days(now, -60)
    )

    land_revision!(org, Battery.Compliance.IntakeRulesRevised, "2", days(now, -59))

    # ── the process ───────────────────────────────────────────────────────
    publish_process!(@process, Battery.Fixtures.scheduled_activation_process())

    # ── the applicants: two in scope, one in another organization ─────────
    small =
      Ash.create!(Applicant, %{
        organization_id: org,
        name: "a-small",
        identified: true,
        amount: 250
      })

    large =
      Ash.create!(Applicant, %{
        organization_id: org,
        name: "b-large",
        identified: true,
        amount: 5000
      })

    outside =
      Ash.create!(Applicant, %{
        organization_id: other_org,
        name: "c-outside",
        identified: true,
        amount: 5000
      })

    %{
      now: now,
      org: org,
      small: small,
      large: large,
      outside: outside,
      standing_definition: standing_definition
    }
  end

  test "a future-dated activation leaves today's answer unchanged", ctx do
    %{now: now, small: small, large: large} = ctx
    effective_at = days(now, 30)

    # under revision 1 alone, both applicants proceed — today and at the
    # future instant alike
    assert standing!(small, now) == "proceed"
    assert standing!(large, now) == "proceed"
    assert standing!(large, days(effective_at, 1)) == "proceed"

    instance = start!(ctx.org, effective_at)

    # ── parked on the timer: nothing has been activated or re-evaluated ───
    assert instance.status != :completed
    assert TestJobs.fire_due!(DateTime.utc_now()) == 0
    assert recorded_standings(ctx.standing_definition) == %{}
    assert standing!(large, days(effective_at, 1)) == "proceed"

    # ── the timer fires ───────────────────────────────────────────────────
    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 2, :hour)) == 1

    instance = Ash.get!(Instance, instance.id)
    assert instance.status == :completed
    assert instance.outcome == "activated"
    assert invoked() == ["activate_scheduled_revision", "reevaluate_scope"]

    # every applicant in scope was re-evaluated once, as of now — and
    # today's answer is unchanged, because revision 2 is not yet in force
    assert recorded_standings(ctx.standing_definition) == %{
             Standing.correlation_id(small) => "proceed",
             Standing.correlation_id(large) => "proceed"
           }

    refute Map.has_key?(
             recorded_standings(ctx.standing_definition),
             Standing.correlation_id(ctx.outside)
           )

    # the activation answers from its effective instant on, and only then
    assert standing!(large, now) == "proceed"
    assert standing!(large, days(effective_at, -1)) == "proceed"
    assert standing!(large, days(effective_at, 1)) == "hold"
    assert standing!(small, days(effective_at, 1)) == "proceed"
  end

  test "a backdated activation changes the as-of answer", ctx do
    %{now: now, small: small, large: large} = ctx
    effective_at = days(now, -10)

    assert standing!(large, days(now, -5)) == "proceed"
    assert standing!(large, now) == "proceed"

    instance = start!(ctx.org, effective_at)

    assert TestJobs.fire_due!(DateTime.utc_now()) == 0
    assert recorded_standings(ctx.standing_definition) == %{}
    assert standing!(large, days(now, -5)) == "proceed"

    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 2, :hour)) == 1

    instance = Ash.get!(Instance, instance.id)
    assert instance.status == :completed
    assert invoked() == ["activate_scheduled_revision", "reevaluate_scope"]

    # the re-evaluation recorded today's changed answer for every applicant
    # in scope: revision 2 has been in force for ten days
    assert recorded_standings(ctx.standing_definition) == %{
             Standing.correlation_id(small) => "proceed",
             Standing.correlation_id(large) => "hold"
           }

    # the as-of answer after the backdated instant changed; before it, the
    # answer revision 1 gave stands
    assert standing!(large, days(now, -5)) == "hold"
    assert standing!(large, days(now, -20)) == "proceed"
    assert standing!(small, days(now, -5)) == "proceed"
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp days(at, n), do: DateTime.add(at, n * 86_400, :second)

  # Probe the answer without recording it: the recorded evaluations are
  # what the process wrote, nothing else.
  defp standing!(applicant, at) do
    {:ok, standing} = Standing.as_of(applicant, at, record: false)
    standing
  end

  defp start!(org, effective_at) do
    request =
      Ash.create!(ScheduledActivation, %{
        organization_id: org,
        rule_set_name: @rule_set,
        revision: "2",
        effective_at: effective_at
      })

    {:ok, instance} = AshBpmn.start_instance(Battery.Domain, process: @process, subject: request)
    instance
  end

  defp invoked do
    Enum.map(Invoker.recorded_calls(), fn {_id, action, _ts} -> action end)
  end

  defp recorded_standings(definition) do
    Battery.Decisions.Evaluation
    |> Ash.Query.filter(definition_id == ^definition.id)
    |> Ash.read!()
    |> Map.new(fn evaluation -> {evaluation.correlation_id, evaluation.outputs["value"]} end)
  end

  # Lands a revision's lifecycle at declared instants, a day apart from
  # `drafted_at`: draft, validate, approve, and (optionally) activate.
  defp land_revision!(org, module, revision, drafted_at, opts \\ []) do
    bundle = module.__bundle__()

    approved =
      RuleSetRevision
      |> Ash.Changeset.for_create(
        :draft,
        %{
          organization_id: org,
          name: @rule_set,
          revision: revision,
          layer: :global_mandatory,
          combining: :deny_overrides,
          rules_json: AshRules.Ir.encode!(bundle),
          content_hash: bundle.content_hash
        },
        as_of: drafted_at,
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:validate, %{}, as_of: days(drafted_at, 1), authorize?: false)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:approve, %{}, as_of: days(drafted_at, 2), authorize?: false)
      |> Ash.update!()

    case Keyword.fetch(opts, :activate_at) do
      {:ok, at} ->
        AshCompliance.Domain.activate_rule_set_revision!(approved, %{effective_at: at},
          authorize?: false
        )

      :error ->
        approved
    end
  end

  defp publish_process!(key, xml) do
    defn = Definition.create!(%{key: key, name: "Battery #{key}", xml: xml})

    if defn.graph do
      Battery.Repo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end
end

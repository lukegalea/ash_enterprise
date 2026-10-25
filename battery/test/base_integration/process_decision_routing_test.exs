defmodule Battery.Integration.ProcessDecisionRoutingTest do
  @moduledoc """
  Scenario 2 — process ↔ decisions.

  The routing seam: a BPMN `businessRuleTask` carries a decision REFERENCE
  (never a rule table); the reference is verified against the resolver at
  publish time; the engine evaluates the declared FEEL inputs off the
  subject, the resolver routes the reference into ash_decisions (load the
  latest PUBLISHED definition, evaluate, record), and the engine promotes
  ONE declared scalar signal onto the token, which the gateway routes on.

  Asserted: the process token consumed the DMN decision's OUTPUT; the
  definition's key/version and the engine's matched rule ids crossed the
  seam into a recorded ash_decisions Evaluation row; the same diagram takes
  both branches from the same decision.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Battery.Bpmn.{Definition, Invoker, Subject}

  @battery_tables [Battery.Decisions.Definition, Battery.Decisions.Evaluation]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    Enum.each(@battery_tables, &Battery.Repo.delete_all(&1))

    for table <- ~w(bpmn_definitions bpmn_instances bpmn_tokens bpmn_process_events
                    bpmn_test_subjects) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    Invoker.clear_calls()

    # The engine routes decisions through THIS resolver for the scenario.
    previous = Application.get_env(:ash_bpmn, :decision_resolver)
    Application.put_env(:ash_bpmn, :decision_resolver, Battery.Bpmn.DecisionResolver)

    on_exit(fn ->
      Invoker.clear_calls()

      if previous do
        Application.put_env(:ash_bpmn, :decision_resolver, previous)
      else
        Application.delete_env(:ash_bpmn, :decision_resolver)
      end
    end)

    :ok
  end

  test "a business-rule task routes on a published DMN decision's output" do
    # ── the decision side: publish the DMN document FIRST, so the process
    #    definition's publish-time reference check finds it ────────────────
    tier_definition =
      Battery.Decisions.Definition.create!(%{
        key: "battery_risk_tier",
        name: "Battery risk tier",
        xml: Battery.Fixtures.risk_tier_dmn()
      })

    assert tier_definition.graph

    {:ok, tier_definition} = Battery.Decisions.Definition.publish(tier_definition)
    assert tier_definition.status == :published

    # ── the process side: the XML is the single artifact ──────────────────
    process = publish_process!("battery_risk", Battery.Fixtures.risk_tier_process())

    # ── the HIGH branch (amount >= 1000) ──────────────────────────────────
    subject = Ash.create!(Subject, %{name: "battery_risk_high", amount: 5000})

    {:ok, instance} =
      AshBpmn.start_instance(Battery.Domain, process: "battery_risk", subject: subject)

    assert instance.status == :completed
    assert instance.outcome == "escalated"
    assert Enum.any?(Invoker.recorded_calls(), fn {_id, action, _ts} -> action == "escalate" end)

    # the token consumed the DMN output: the decision task promoted the
    # decision table's `tier` output onto the token's routing, and the
    # engine recorded WHICH definition version and rule ids decided
    assert promoted = decision_event(instance.id, "AssessRisk")

    assert promoted["promoted"] == %{"tier" => "high"}
    assert promoted["decision_ref"] == "battery_risk_tier"
    # version crosses the seam as the string spelling events persist
    assert promoted["decision_version"] == to_string(tier_definition.version)
    assert promoted["rule_ids"] == ["rule_high"]

    # and the seam left its evidence: a recorded ash_decisions evaluation,
    # keyed to the definition VERSION the process resolved, with the
    # engine's own matched rule ids.
    assert [evaluation] = evaluations_for(tier_definition)

    assert evaluation.definition_key == "battery_risk_tier"
    assert evaluation.definition_version == tier_definition.version
    assert evaluation.matched_rule_ids == ["rule_high"]
    assert evaluation.outputs["value"] == "high"
    assert evaluation.decision_id == "battery_risk_tier"
    assert Decimal.eq?(Decimal.new(evaluation.inputs["amount"]), Decimal.new(5000))

    # the instance pinned the process definition it ran
    assert instance.definition_id == process.id

    # ── the LOW branch: same diagram, same decision, other side ───────────
    Invoker.clear_calls()
    low_subject = Ash.create!(Subject, %{name: "battery_risk_low", amount: 250})

    {:ok, low_instance} =
      AshBpmn.start_instance(Battery.Domain, process: "battery_risk", subject: low_subject)

    assert low_instance.status == :completed
    assert low_instance.outcome == "approved"
    assert decision_event(low_instance.id, "AssessRisk")["promoted"] == %{"tier" => "low"}
    assert Enum.any?(Invoker.recorded_calls(), fn {_id, action, _ts} -> action == "auto_approve" end)

    assert [_, second_evaluation] = evaluations_for(tier_definition)
    assert second_evaluation.matched_rule_ids == ["rule_low"]
  end

  test "a process cannot publish against a decision reference that does not exist" do
    # The check that makes a decision node safe: the reference is verified
    # against the ash_decisions-backed resolver at COMPILE time — a diagram
    # cannot ship against a decision that is not published.
    assert {:error, errors} = AshBpmn.Compiler.compile(Battery.Fixtures.risk_tier_process())

    assert Enum.any?(errors, fn e ->
             String.contains?(e.message, "battery_risk_tier") and
               String.contains?(e.message, "does not exist")
           end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────

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

  defp decision_event(instance_id, node_id) do
    [event] =
      Battery.Bpmn.ProcessEvent
      |> Ash.Query.filter(instance_id == ^instance_id and kind == :decision_evaluated)
      |> Ash.Query.filter(node_id == ^node_id)
      |> Ash.read!()

    event.data
  end

  defp evaluations_for(definition) do
    Battery.Decisions.Evaluation
    |> Ash.Query.filter(definition_id == ^definition.id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end
end

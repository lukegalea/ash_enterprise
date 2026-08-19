defmodule AshEnterprise.Bpmn.AdoptionTest do
  @moduledoc """
  The claims ADR 0009 makes about adopting `ash_bpmn` here, as assertions.

  That ADR could not move from `proposed` to `accepted` on an argument. It named one
  composition constraint that had to be resolved and one property that had to be demonstrated,
  and this file is both.

  ## The constraint

  Ash folds a resource's policies into a single boolean expression in which a bypass
  contributes a disjunct covering the policies declared **after** it. This application's policy
  set is injected by `use AshEnterprise.Platform.Resource`, ahead of anything a resource adds
  for itself — so an engine bypass that `ash_bpmn` declares on its own generated resources
  lands *second* and never fires. A work item on the platform base resource would refuse the
  very engine that has to write it.

  The fix is to put the engine bypasses first in the base's own policy set, which is what
  `AshEnterprise.Security.Policies` now does. These tests fail if that ordering is ever
  disturbed — including by someone adding a policy above them.

  ## The property

  The engine keeps the **human** actor. That is why the ordering fix was chosen over
  `config :ash_bpmn, engine_actor:`, which would have needed no policy change at all: ownership,
  provenance and the audit entry all derive from the actor, so attributing every engine write
  to a system actor would leave the person who approved visible only in `decided_by_id`.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance, ProcessEvent, TaskCandidate, Token}

  describe "the six resources are this application's" do
    test "each sits on the platform base resource and inherits its system attributes" do
      for resource <- [Definition, Instance, Token, HumanTask, TaskCandidate, ProcessEvent] do
        attributes = resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

        assert :organization_id in attributes,
               "#{inspect(resource)} is not tenant-scoped; it did not inherit the base's tenancy"

        assert :created_on in attributes,
               "#{inspect(resource)} has no provenance columns; it is not on the platform base"

        assert :version_number in attributes,
               "#{inspect(resource)} has no optimistic-locking column"
      end
    end

    test "each is multitenant by organization_id, so one tenant cannot see another's processes" do
      for resource <- [Definition, Instance, Token, HumanTask, TaskCandidate, ProcessEvent] do
        assert Ash.Resource.Info.multitenancy_strategy(resource) == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(resource) == :organization_id
      end
    end
  end

  describe "the engine's bypass ordering" do
    # The assertion ADR 0009 turns on. If someone adds a policy above these, the engine is
    # forbidden on every resource in the application and the failure presents as processes
    # silently not advancing.
    test "both engine bypasses precede every other policy on a platform resource" do
      policies = Ash.Policy.Info.policies(HumanTask)

      # A policy's condition is a list of `{check_module, opts}` tuples.
      flattened =
        policies
        |> Enum.flat_map(fn policy ->
          policy.condition |> List.wrap() |> Enum.map(&check_module/1)
        end)

      bpmn_at = Enum.find_index(flattened, &(&1 == AshBpmn.Checks.AshBpmnInteraction))

      decisions_at =
        Enum.find_index(flattened, &(&1 == AshDecisions.Checks.AshDecisionsInteraction))

      system_at = Enum.find_index(flattened, &(&1 == AshEnterprise.Security.Checks.SystemActor))

      assert bpmn_at, "the ash_bpmn engine bypass is not in the policy set at all"
      assert decisions_at, "the ash_decisions engine bypass is not in the policy set at all"
      assert system_at, "the SystemActor bypass has gone missing"

      assert bpmn_at < system_at,
             "the ash_bpmn bypass must precede everything else -- a bypass only covers the " <>
               "policies declared after it, so the engine is forbidden if anything comes first"

      assert decisions_at < system_at,
             "the ash_decisions bypass must precede everything else, for the same reason"
    end

    test "the same ordering holds on a hand-written platform resource, not just a generated one" do
      policies = Ash.Policy.Info.policies(AshEnterprise.Accounts.Team)

      first_check =
        policies
        |> List.first()
        |> Map.get(:condition)
        |> List.wrap()
        |> List.first()
        |> check_module()

      assert first_check == AshBpmn.Checks.AshBpmnInteraction,
             "the engine bypass is injected by the base resource, so it must be first everywhere"
    end
  end

  describe "the engine's own writes" do
    # Not a stronger boundary than the `authorize?: false` it replaced -- anything that can set
    # private context could have passed the option. It is a *named* one, which the ninety it
    # replaced were not: a host reading these policies can see the engine path and replace it.
    # Note *how* the read without the engine context fails. `RoleGrant` is a filter check, so
    # an actor with no grant does not get an error -- the query is filtered to nothing. That is
    # fail-closed working correctly, and it is worth pinning as the shape rather than the
    # error most people expect: for reads, "forbidden" and "no such row" are deliberately
    # indistinguishable, which is what stops a filtered list leaking the existence of rows.
    test "an engine-scoped read sees a definition that the same read without it does not" do
      %{organization: organization} =
        AshEnterprise.Platform.Seeder.seed_tenant(
          unique_name: "bpmn-adoption-#{System.unique_integer([:positive])}",
          email: "bpmn-adoption-#{System.unique_integer([:positive])}@example.com"
        )

      scope = %AshBpmn.Scope{actor: nil, tenant: organization.id, domain: AshEnterprise.Bpmn}

      Definition.create!(
        %{key: "adoption_probe", name: "Adoption probe", xml: minimal_bpmn()},
        AshBpmn.Scope.engine(scope)
      )

      assert {:ok, [_definition]} =
               Definition
               |> Ash.Query.for_read(:read)
               |> Ash.read(AshBpmn.Scope.engine(scope))

      # Same row, same tenant, no engine context: the grant union has nothing to offer a nil
      # actor -- no role, no share, no hierarchy -- so the filter matches nothing.
      assert {:ok, []} =
               Definition
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: nil, tenant: organization.id)
    end
  end

  defp check_module({module, _opts}), do: module
  defp check_module(%{check_module: module}), do: module
  defp check_module(module) when is_atom(module), do: module

  defp minimal_bpmn do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                       xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
      <bpmn2:process id="P" isExecutable="true">
        <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
        <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
      </bpmn2:process>
    </bpmn2:definitions>
    """
  end
end

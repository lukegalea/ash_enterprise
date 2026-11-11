defmodule AshEnterprise.Bpmn.EngineBypassTest do
  @moduledoc """
  The engines' authority on the process and decision resources is the platform's
  narrowed bypass and nothing else (ADR 0059, ADR 0043).

  Every `ash_bpmn` and `ash_decisions` resource macro emits its own engine bypass,
  `authorize_if always()`, unless it is given `policies?: false`. On a resource that also
  sits on `AshEnterprise.Platform.Resource` that bypass lands after the platform's policy
  set, and it is not narrowed. For a call that no earlier policy applies to, it is the
  only policy left, and it authorizes. An automation principal on a `human_only` action
  is exactly such a call: the grant union does not apply to it (`GrantReach`), the
  platform's engine bypass does not reach the action (`EngineReach`), and the macro's
  bypass then let an engine-marked call carrying the principal decide a person's task.

  The host resources pass `policies?: false` to the macros, so the platform's bypasses,
  which already precede everything and reach every action that is not narrowed, are the
  engines' only way in. This file pins both halves: nothing an engine marks reaches a
  narrowed action unless the actor's own grants do, and everything the engine did before
  still works.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Platform.{AutomationPrincipal, SystemActor}
  alias AshEnterprise.Security.{ActionReach, ActorContext}
  alias AshEnterprise.Security.Checks.{EngineReach, SystemActorReach}

  @engine_checks [AshBpmn.Checks.AshBpmnInteraction, AshDecisions.Checks.AshDecisionsInteraction]
  @human_only [:approve, :reject, :request_info, :resolve, :settle, :answer]
  @bpmn {"flagged by ash_bpmn", %{private: %{ash_bpmn?: true}}}
  @decisions {"flagged by ash_decisions", %{private: %{ash_decisions?: true}}}

  describe "the policy set" do
    # On a resource that narrows nothing, an engine bypass that authorizes `always()` reaches
    # what `EngineReach` would; the hand-written MDM policy sets are such resources, and gate
    # their person-only actions with a policy that precedes their bypasses. Once a resource
    # declares an action `human_only` or `machinery_only`, every engine bypass on it must be
    # the narrowed one.
    test "on every resource that narrows an action, each engine bypass authorizes through EngineReach only" do
      narrowing =
        for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(resource),
            ActionReach.human_only(resource) != [] or ActionReach.machinery_only(resource) != [],
            uniq: true,
            do: resource

      assert HumanTask in narrowing

      offenders =
        for resource <- narrowing,
            %{bypass?: true} = policy <- Ash.Policy.Info.policies(resource),
            engine_condition?(policy),
            body = Enum.map(policy.policies, &{&1.type, &1.check_module}),
            body != [{:authorize_if, EngineReach}],
            do: {resource, body}

      assert offenders == []
    end

    test "the process and decision resources carry the platform's three bypasses and no other" do
      resources =
        Ash.Domain.Info.resources(AshEnterprise.Bpmn) ++
          Ash.Domain.Info.resources(AshEnterprise.Decisions)

      assert HumanTask in resources

      for resource <- resources do
        bypasses =
          for %{bypass?: true} = policy <- Ash.Policy.Info.policies(resource) do
            {Enum.map(List.wrap(policy.condition), &check_module/1),
             Enum.map(policy.policies, &{&1.type, &1.check_module})}
          end

        assert bypasses == [
                 {[AshBpmn.Checks.AshBpmnInteraction], [{:authorize_if, EngineReach}]},
                 {[AshDecisions.Checks.AshDecisionsInteraction], [{:authorize_if, EngineReach}]},
                 {[AshEnterprise.Security.Checks.SystemActor],
                  [{:authorize_if, SystemActorReach}]}
               ],
               "#{inspect(resource)} carries a bypass the platform did not put there"
      end
    end
  end

  describe "a person's decision on a human task" do
    setup do
      ctx = tenant!()
      brief = brief!(ctx)
      [task] = HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()
      Map.merge(ctx, %{brief: brief, task: task})
    end

    test "an automation principal acting for the candidate is refused, engine-marked or not",
         ctx do
      principal = acting_for(ctx)

      reached =
        for action <- @human_only,
            {label, context} <- [{"unmarked", %{}}, @bpmn, @decisions],
            can_decide?(ctx, action, principal, context),
            do: {action, label}

      assert reached == []
    end

    test "an engine-marked approve carrying the principal is Forbidden and decides nothing",
         ctx do
      {_label, context} = @bpmn

      assert {:error, %Ash.Error.Forbidden{}} =
               HumanTask
               |> Ash.ActionInput.for_action(:approve, %{record_id: ctx.task.id},
                 actor: acting_for(ctx),
                 tenant: ctx.tenant,
                 context: context
               )
               |> Ash.run_action()

      assert %{status: :pending_approval} = reload_brief!(ctx.brief, ctx.tenant)

      assert [%{status: :open}] =
               HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()
    end

    test "no system actor reaches a decision, flagged by either engine or not", ctx do
      reached =
        for action <- @human_only,
            actor <- SystemActor.all(),
            {label, context} <- [{"unmarked", %{}}, @bpmn, @decisions],
            can_decide?(ctx, action, actor, context),
            do: {action, actor.name, label}

      assert reached == []
    end

    test "the candidate still decides, with or without the engine's flag", ctx do
      for {_label, context} <- [{"unmarked", %{}}, @bpmn] do
        assert can_decide?(ctx, :approve, ctx.actor, context)
        assert can_decide?(ctx, :reject, ctx.actor, context)
      end

      assert {:ok, "Approved — Approve the brief."} =
               HumanTask
               |> Ash.ActionInput.for_action(:approve, %{record_id: ctx.task.id}, opts(ctx))
               |> Ash.run_action()

      # The engine completed the task and advanced the token as the person decided.
      assert %{status: :approved} = reload_brief!(ctx.brief, ctx.tenant)
      assert [] == HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()
    end

    test "the engine still reaches the task's actions that are not narrowed", ctx do
      for {_label, context} <- [@bpmn, @decisions], actor <- [nil, SystemActor.process()] do
        assert ctx.task
               |> Ash.Changeset.for_update(:cancel, %{},
                 actor: actor,
                 tenant: ctx.tenant,
                 context: context
               )
               |> Ash.can?(actor, tenant: ctx.tenant)
      end
    end
  end

  defp opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]

  # The principal at its widest: acting for the task's own candidate.
  defp acting_for(ctx) do
    AutomationPrincipal.acting(
      AutomationPrincipal.evidence_admitter(),
      ctx.user.id,
      "engine-bypass-test",
      ActorContext.intersect(
        ActorContext.build(ctx.user, tenant: ctx.tenant),
        ActorContext.build_automation(:evidence_admitter, ctx.tenant)
      )
    )
  end

  defp can_decide?(ctx, action, actor, context) do
    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: ctx.task.id},
      actor: actor,
      tenant: ctx.tenant,
      context: context
    )
    |> Ash.can?(actor, tenant: ctx.tenant)
  end

  defp engine_condition?(policy),
    do: Enum.any?(List.wrap(policy.condition), &(check_module(&1) in @engine_checks))

  defp check_module({module, _opts}), do: module
  defp check_module(module) when is_atom(module), do: module
end

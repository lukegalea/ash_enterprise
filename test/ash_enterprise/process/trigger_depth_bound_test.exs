defmodule AshEnterprise.Process.TriggerDepthBoundTest do
  @moduledoc """
  A process that writes the resource its own subscription watches stops at
  `trigger_max_depth`.

  The loop is the shortest one the shipped process allows: the access-request process's
  `RecordRisk` service task writes `AccessRequest.record_risk`, and the recipe that starts
  the process on a submitted request also matches that action and starts it again. Each hop is counted in three places that
  must agree: the dispatch that started an instance, the instance's `trigger_depth`, and the
  `metadata.trigger_depth` of the audit row the instance's write produced, which is what the
  trigger sweep reads to count the next hop.

  Before this, the write carried no depth, the correlator started every instance at depth 0,
  and every lap was recorded as a person's write at depth 1: the bound never fired.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Bpmn.{Dispatch, Instance, Subscription}
  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Resolver, ServiceInvocation}
  alias AshEnterprise.Security.{AccessRequest, Role}

  setup do
    platform = Seeder.seed_platform_organization()
    publish_baselines(platform.id)

    %{organization: organization, user: admin, business_unit: unit} =
      Seeder.seed_tenant(
        unique_name: "depth-#{System.unique_integer([:positive])}",
        email: "depth-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    opts = [actor: SystemActor.process(), tenant: organization.id]

    {:ok, draft} = Resolver.fork(:process, "access_request.grant", organization.id, nil)
    AshEnterprise.Bpmn.Definition.publish!(draft, opts)

    # One recipe both starts the process (a person submits a request) and starts it again
    # (the process's own `record_risk` write). One, because only the allowlisted key may
    # run its steps as the causing person; the guard keeps every other write out.
    recipe =
      Subscription.create!(
        %{
          key: "access_request.submitted",
          match_resource: "AshEnterprise.Security.AccessRequest",
          process_key: "access_request.grant",
          guard_feel: ~s(event.action = "submit" or event.action = "record_risk")
        },
        opts
      )
      |> Subscription.set_authority!(:causing_person, opts)
      |> Subscription.publish!(opts)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Depth Reader"},
        actor: SystemActor.seed(),
        tenant: organization.id
      )
      |> Ash.create!()

    %{
      tenant: organization.id,
      admin: admin,
      unit: unit,
      role: role,
      recipe: recipe
    }
  end

  describe "what does not carry a depth" do
    test "a person's own write names no trigger depth", ctx do
      request = submit!(ctx)

      assert [submitted] = events(ctx.tenant, request.id, :submit)
      refute Map.has_key?(submitted.metadata, "trigger_depth")
    end

    test "an invocation key naming no readable instance yields no depth", ctx do
      unknown = "bpmn:#{Ash.UUID.generate()}:#{Ash.UUID.generate()}:RecordRisk"
      assert ServiceInvocation.trigger_depth(unknown, ctx.tenant) == nil
      assert ServiceInvocation.trigger_depth("not-a-bpmn-key", ctx.tenant) == nil
      assert ServiceInvocation.trigger_depth("bpmn:not-a-uuid:t:n", ctx.tenant) == nil
    end

    test "an instance in another tenant yields no depth", ctx do
      request = submit!(ctx)
      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant, request.id)
      key = "bpmn:#{instance.id}:#{Ash.UUID.generate()}:RecordRisk"

      assert ServiceInvocation.trigger_depth(key, ctx.tenant) == instance.trigger_depth
      assert ServiceInvocation.trigger_depth(key, Ash.UUID.generate()) == nil
    end
  end

  test "a process that writes the resource its own subscription watches stops at trigger_max_depth",
       ctx do
    # Privileged, so each instance records the risk and then parks on a human task: one
    # watched write per instance, which keeps the loop linear and countable.
    request = submit!(ctx)

    max_depth = AshBpmn.Config.trigger_max_depth()

    # Each sweep dispatches what the previous hop wrote. Two sweeps more than the bound
    # allows: the last finds nothing left to dispatch.
    for _ <- 1..(max_depth + 2), do: sweep!(ctx.tenant)

    # The dispatches, in hop order: the person's submit at depth 1, each lap one deeper,
    # and the lap past the bound refused.
    dispatches =
      ctx.tenant
      |> dispatches()
      |> Enum.sort_by(&{&1.depth, &1.event_sequence})

    assert Enum.map(dispatches, & &1.depth) == Enum.to_list(1..(max_depth + 1))

    {started, [refused]} = Enum.split(dispatches, max_depth)
    assert Enum.all?(started, &(&1.status == :started))
    assert Enum.all?(dispatches, &(&1.subscription_id == ctx.recipe.id))

    assert refused.status == :failed
    assert refused.reason == :depth_exceeded
    assert refused.instance_id == nil

    # One instance per started dispatch, at that dispatch's depth, and none for the refusal.
    instances = instances(ctx.tenant, request.id)
    assert length(instances) == max_depth

    by_id = Map.new(instances, &{&1.id, &1})

    for dispatch <- started do
      assert by_id[dispatch.instance_id].trigger_depth == dispatch.depth
    end

    # Each instance's write names the hop it made it at: the audit rows the next lap is
    # counted from.
    risk_depths =
      ctx.tenant
      |> events(request.id, :record_risk)
      |> Enum.map(&{&1.metadata["system_actor"], &1.metadata["trigger_depth"]})

    assert risk_depths == Enum.map(1..max_depth, &{"process", &1})

    assert Enum.sort(Enum.map(instances, & &1.trigger_depth)) == Enum.to_list(1..max_depth)
  end

  test "a write by an invocation executed outside the service task's job keeps its instance's depth",
       ctx do
    request = submit!(ctx)
    sweep!(ctx.tenant)
    sweep!(ctx.tenant)

    instance =
      ctx.tenant
      |> instances(request.id)
      |> Enum.max_by(& &1.trigger_depth)

    assert instance.trigger_depth == 2

    request =
      AccessRequest
      |> Ash.Query.filter(id == ^request.id)
      |> Ash.read_one!(actor: SystemActor.process(), tenant: ctx.tenant)

    # No process scope here, as for a worker that picked the invocation up later: only the
    # invocation key in the action context names the instance.
    request
    |> Ash.Changeset.for_update(:record_risk, %{risk_tier: request.risk_tier},
      actor: SystemActor.process(),
      tenant: ctx.tenant,
      context: %{
        ash_agent: %{invocation_key: "bpmn:#{instance.id}:#{Ash.UUID.generate()}:RecordRisk"}
      }
    )
    |> Ash.update!()

    latest = ctx.tenant |> events(request.id, :record_risk) |> List.last()
    assert latest.metadata["trigger_depth"] == 2
  end

  defp submit!(ctx) do
    AccessRequest.submit!(
      %{
        justification: "I need this to run the quarterly compliance report for my region.",
        requested_role_tier: :privileged,
        requested_role_id: ctx.role.id,
        scoping_business_unit_id: ctx.unit.id
      },
      actor: ctx.admin,
      tenant: ctx.tenant
    )
  end

  defp sweep!(tenant) do
    AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
  end

  defp events(tenant, record_id, action) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      resource == ^AccessRequest and record_id == ^record_id and action == ^action
    )
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp dispatches(tenant) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp instances(tenant, subject_id) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp publish_baselines(platform) do
    opts = [actor: SystemActor.process(), tenant: platform]

    for {glob, resource} <- [
          {"priv/dmn/*.dmn", Decisions.Definition},
          {"priv/bpmn/*.bpmn", AshEnterprise.Bpmn.Definition}
        ],
        path <- Path.wildcard(glob) do
      key =
        path
        |> Path.basename()
        |> Path.rootname()
        |> then(fn name ->
          parts = String.split(name, "_")
          Enum.join(Enum.drop(parts, -1), "_") <> "." <> List.last(parts)
        end)

      unless resource
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(key == ^key and status == :published)
             |> Ash.read!(opts)
             |> Enum.any?() do
        definition = resource.create!(%{key: key, name: key, xml: File.read!(path)}, opts)
        resource.publish!(definition, opts)
      end
    end
  end
end

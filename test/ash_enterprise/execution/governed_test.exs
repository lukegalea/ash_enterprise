defmodule AshEnterprise.Execution.GovernedTest do
  @moduledoc """
  Governed targets (ADR 0055) run only through their own invocation
  (`AshAgent.Validations.Governed`): the role assignment `assign_governed`, behind the
  `/mcp` `assign_role` tool, and the clinic's credential activation. A context naming an
  invocation is not enough on its own: the validation reads the row, and refuses one that
  is not executing under that lease, one requested with other arguments, and an actor it
  does not execute as.
  """

  use AshEnterprise.DataCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, colleague!: 2]

  require Ash.Query

  alias AshAgent.Invocation.{Executor, Ungoverned}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing.{Credential, DemoData}
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.{ActorContext, UserRole}

  @assign "AshEnterprise.Security.UserRole.assign_governed"

  setup do
    ctx = tenant!()
    %{ctx: ctx, approver: colleague!(ctx, admin?: true), newcomer: colleague!(ctx)}
  end

  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp assign(%{actor: actor, tenant: tenant}, inputs, context) do
    UserRole
    |> Ash.Changeset.for_create(:assign_governed, inputs,
      actor: actor,
      tenant: tenant,
      context: context
    )
    |> Ash.create()
  end

  defp refusal({:error, %Ash.Error.Invalid{errors: errors}}) do
    assert [%Ungoverned{reason: reason}] = Enum.filter(errors, &match?(%Ungoverned{}, &1))
    reason
  end

  defp roles_of(user, tenant) do
    UserRole
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  # Requested by `ctx`'s person, approved by `approver` and applied as the job runner
  # applies it: a ready row, not yet claimed.
  defp approved!(ctx, approver, args) do
    row = Execution.invoke!(@assign, args, %{key: "test:#{Ash.UUIDv7.generate()}"}, ctx_opts(ctx))
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: approver.actor,
      tenant: ctx.tenant
    )
    |> Ash.run_action!()

    %{status: :ready} = Execution.apply_invocation_decision!(row, oban(ctx.tenant))
  end

  defp ctx_opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]

  defp claimed!(row, tenant) do
    {:ok, claimed} = Executor.claim(row, oban(tenant))
    claimed
  end

  test "called directly, even by an administrator, the governed assignment is refused", %{
    ctx: ctx,
    newcomer: newcomer
  } do
    inputs = %{user_id: newcomer.user.id, role_id: ctx.role.id}

    assert :no_invocation = refusal(assign(ctx, inputs, %{}))
    assert roles_of(newcomer.user, ctx.tenant) == []
  end

  test "a forged context is refused: a row awaiting approval, ready, or another epoch", %{
    ctx: ctx,
    approver: approver,
    newcomer: newcomer
  } do
    args = %{"user_id" => newcomer.user.id, "role_id" => ctx.role.id}

    pending =
      Execution.invoke!(@assign, args, %{key: "test:#{Ash.UUIDv7.generate()}"}, ctx_opts(ctx))

    assert pending.status == :awaiting_approval

    forged = %{ash_agent: Map.put(Executor.context(pending), :lease_epoch, 0)}
    assert :not_executing = refusal(assign(ctx, args, forged))

    ready = approved!(ctx, approver, args)
    assert :not_executing = refusal(assign(ctx, args, %{ash_agent: Executor.context(ready)}))

    claimed = claimed!(ready, ctx.tenant)
    later = Map.update!(Executor.context(claimed), :lease_epoch, &(&1 + 1))
    assert :not_executing = refusal(assign(ctx, args, %{ash_agent: later}))

    # A row of another tenant is not found from this one.
    other = tenant!()

    assert :unknown_invocation =
             refusal(assign(other, args, %{ash_agent: Executor.context(claimed)}))

    assert roles_of(newcomer.user, ctx.tenant) == []
  end

  test "the requester cannot run it beside the executor with a context they wrote", %{
    ctx: ctx,
    approver: approver,
    newcomer: newcomer
  } do
    args = %{"user_id" => newcomer.user.id, "role_id" => ctx.role.id}
    claimed = ctx |> approved!(approver, args) |> claimed!(ctx.tenant)

    # The requester knows the row's id from invoke, and the epoch is a small counter;
    # the claim's secret never leaves the executor.
    written = %{ash_agent: %{invocation_id: claimed.id, lease_epoch: claimed.lease_epoch}}
    assert :not_executor = refusal(assign(ctx, args, written))

    assert :not_executor =
             refusal(assign(ctx, args, put_in(written, [:ash_agent, :lease_token], "guess")))

    assert roles_of(newcomer.user, ctx.tenant) == []

    # The executor's run, with the secret, assigns it once.
    assert {:ok, :succeeded} = Executor.run_claimed(claimed, oban(ctx.tenant))
    assert [_assigned] = roles_of(newcomer.user, ctx.tenant)
  end

  test "an approved, executing invocation does not cover other arguments or another actor", %{
    ctx: ctx,
    approver: approver,
    newcomer: newcomer
  } do
    args = %{"user_id" => newcomer.user.id, "role_id" => ctx.role.id}
    claimed = ctx |> approved!(approver, args) |> claimed!(ctx.tenant)
    context = %{ash_agent: Executor.context(claimed)}

    # Approved for the newcomer: not for the approver, nor in another scope.
    assert :other_arguments =
             refusal(assign(ctx, %{args | "user_id" => approver.user.id}, context))

    assert :other_arguments =
             refusal(
               assign(
                 ctx,
                 Map.put(args, "scoping_business_unit_id", ctx.business_unit.id),
                 context
               )
             )

    # Approved for the requester to run: the approver may not run it as themselves.
    assert :other_principal = refusal(assign(approver, args, context))
    assert :other_principal = refusal(assign(%{ctx | actor: SystemActor.oban()}, args, context))

    assert roles_of(newcomer.user, ctx.tenant) == []
    assert roles_of(approver.user, ctx.tenant) |> Enum.map(& &1.role_id) == [ctx.role.id]
  end

  test "the clinic's credential activation is governed too" do
    admin = AshEnterprise.Test.DailyFixtures.tenant!()
    clinic = DemoData.populate(admin.tenant)
    [credential | _] = clinic.credentials

    coordinator = colleague_actor(clinic.coordinator, admin.tenant)

    assert :no_invocation =
             credential
             |> Ash.Changeset.for_update(:activate_credential, %{},
               actor: coordinator,
               tenant: admin.tenant
             )
             |> Ash.update()
             |> refusal()

    assert Ash.get!(Credential, credential.id, authorize?: false, tenant: admin.tenant).status ==
             :pending
  end

  defp colleague_actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))
end

defmodule AshEnterprise.Execution.AttemptOutcomesTest do
  @moduledoc """
  An attempt's outcome is recorded as what can be known of it (ADR 0055, invariant A and
  failure scenario F2): a row never ends as though nothing ran when its target may have
  reached outside, and never runs on a subject other than the one approved.

  The clinic's `activate_credential` calls the registry before its own write and needs
  four eyes; `ReferralBoard.refer_keyed` sends a referral through the Nango façade to
  `AshEnterprise.Test.Execution.FakeBoard` and is idempotent. Each test moves something
  between the steps the executor takes, as a concurrent writer or a deploy would.

  Durability tier: claims, completions and the concurrent writes commit for real. The
  `:execution` queue is paused, so each test drives the executor itself.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing.{Credential, DemoData}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Invocation}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.FakeBoard

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"

  setup do
    subscribe_jobs()
    pause_execution!()
    FakeBoard.start!()
    %{admin: admin, nurse: nurse, tenant: tenant} = clinic!()
    %{admin: admin, nurse: nurse, tenant: tenant, clinic: DemoData.populate(tenant)}
  end

  defp as_person(user, tenant),
    do: [
      actor: ActorContext.attach(user, ActorContext.build(user, tenant: tenant)),
      tenant: tenant
    ]

  defp execute(row, tenant), do: Executor.execute(Invocation, row.id, oban(tenant))

  # The coordinator asks to activate a credential, a committee member approves, and the
  # decision is applied as the `:apply_decision` job applies it: a ready row.
  defp ready_activation!(%{clinic: clinic, tenant: tenant}) do
    [credential | _] = clinic.credentials

    row =
      Execution.invoke!(
        @activate,
        %{"id" => credential.id},
        %{key: "activate:#{System.unique_integer([:positive])}"},
        as_person(clinic.coordinator, tenant)
      )

    key = Approval.key()
    id = row.id

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    HumanTask
    |> Ash.ActionInput.for_action(
      :approve,
      %{record_id: task.id},
      as_person(hd(clinic.committee), tenant)
    )
    |> Ash.run_action!()

    %{status: :ready} = ready = Execution.apply_invocation_decision!(row, oban(tenant))
    {ready, credential}
  end

  # Another write to the credential, made outside the invocation: its version moves on.
  defp edited!(credential) do
    {1, _} =
      AshEnterprise.Repo.update_all(
        from(c in "credentialing_credentials",
          where: c.id == type(^credential.id, Ecto.UUID),
          update: [inc: [version_number: 1]]
        ),
        []
      )

    :ok
  end

  defp status_of(credential, tenant),
    do: Ash.get!(Credential, credential.id, authorize?: false, tenant: tenant).status

  defp outcome(row, tenant),
    do: committed(row.id, tenant) |> Map.take([:status, :failure_class, :error_code])

  test "a credential edited after the claim is not activated under its approval (F4)", ctx do
    {ready, credential} = ready_activation!(ctx)
    {:ok, claimed} = Executor.claim(ready, oban(ctx.tenant))

    # The claim found the approval good. A concurrent edit commits before the run.
    edited!(credential)

    assert {:ok, :stale} = Executor.run_claimed(claimed, oban(ctx.tenant))

    assert outcome(ready, ctx.tenant) == %{
             status: :stale,
             failure_class: nil,
             error_code: "subject_changed"
           }

    assert status_of(credential, ctx.tenant) == :pending
  end

  test "an edit racing the registry call leaves the activation in doubt, never rejected (F2)",
       ctx do
    {ready, credential} = ready_activation!(ctx)
    handler = "edit-during-registry-call-#{System.unique_integer([:positive])}"
    test = self()

    # Once the update starts, before the registry is called, another writer commits:
    # the activation reaches the registry and then loses its own write's version race.
    :telemetry.attach(
      handler,
      [:ash, :credentialing, :update, :start],
      fn _event, _measurements, _metadata, _config ->
        :telemetry.detach(handler)
        edited!(credential)
        send(test, :edited)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, :deferred} = execute(ready, ctx.tenant)
    assert_received :edited

    # Idempotent: it may run again with the same key, and is not final.
    assert %{status: :ready, failure_class: :transient} = outcome(ready, ctx.tenant)

    # The next attempt finds the credential changed since its approval. An earlier attempt
    # reached the registry, so the row is left for reconciliation rather than called stale.
    elapse!(ready, :next_attempt_at)
    assert {:ok, :outcome_unknown} = execute(ready, ctx.tenant)

    assert %{status: :outcome_unknown, error_code: "subject_changed"} =
             outcome(ready, ctx.tenant)
  end

  test "a connector call that raises is recorded, and stops at max_attempts (F2)", %{
    nurse: nurse,
    tenant: tenant
  } do
    Faults.arm(:referral_accepted, :raise, times: :infinity)
    {:ok, row} = refer(nurse, :refer_keyed)

    assert {:ok, :deferred} = execute(row, tenant)
    elapse!(row, :next_attempt_at)
    assert {:ok, :deferred} = execute(row, tenant)
    elapse!(row, :next_attempt_at)

    # The third attempt is the last: the board may hold the referral, so its outcome is
    # unknown, not failed, and nothing runs it again.
    assert {:ok, :outcome_unknown} = execute(row, tenant)
    assert {:ok, :skipped} = execute(row, tenant)

    done = committed(row.id, tenant)
    assert {done.status, done.error_code, done.attempt_count} == {:outcome_unknown, "raised", 3}
    assert {FakeBoard.calls(), FakeBoard.referrals()} == {3, 1}
  end

  test "a referral the board took before a deploy is reconciled, not called stale (F2)", %{
    nurse: nurse,
    tenant: tenant
  } do
    Faults.arm(:referral_accepted, :raise, times: 1)
    {:ok, row} = refer(nurse, :refer_keyed)

    assert {:ok, :deferred} = execute(row, tenant)
    assert FakeBoard.referrals() == 1

    # A deploy changes the target before the next attempt.
    requested_under_earlier_definition!(row)
    elapse!(row, :next_attempt_at)

    assert {:ok, :outcome_unknown} = execute(row, tenant)
    assert %{status: :outcome_unknown, error_code: "target_changed"} = outcome(row, tenant)
    assert {FakeBoard.calls(), FakeBoard.referrals()} == {1, 1}
  end
end

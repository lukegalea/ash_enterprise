defmodule AshEnterprise.AgentSpike.S3InternalEffectTransactionTest do
  @moduledoc """
  Spike S3: an internal effect and its completion in one transaction, with
  outbound HTTP blocked.

  **Reading tested.** For a target that only writes this repository, the
  executor can run the target and record success in one transaction, so the
  effect commits exactly once: either both rows commit or neither does, and
  an expired lease can safely re-ready the work. The guarantee holds only if
  the target makes no outbound call inside that transaction, so a contract
  test runs each such target with outbound HTTP blocked and fails on any
  attempt.

  **Result: holds.** On `AshEnterprise.Canonical.Task` (audited, real
  table): the target's write, its audit event and the stand-in completion
  commit together; when the completion fails, the target's write and its
  audit event roll back with it; a retry then commits once. With the
  integration façade stubbed to refuse and report every request, a plain
  target records no attempt, and a target carrying a hook that calls out is
  caught: inside the enclosing transaction an `after_transaction` hook runs
  before the commit, so the attempt is reported while the transaction can
  still roll back.

  What it does not cover: the block is the integration façade
  (`AshEnterprise.Integration.Nango.Proxy`, the one outbound path for
  provider calls). Model calls go through `AshEnterprise.AI.Models` and are
  not covered here; the CI contract test (plan Risk 5) must stub both.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Platform.SystemActor

  setup do
    previous = System.get_env("NANGO_SECRET_KEY")
    System.put_env("NANGO_SECRET_KEY", "spike-not-a-secret")

    on_exit(fn ->
      if previous,
        do: System.put_env("NANGO_SECRET_KEY", previous),
        else: System.delete_env("NANGO_SECRET_KEY")
    end)

    test_pid = self()

    # Outbound HTTP blocked: every request through the façade is refused and
    # reported to the test.
    Req.Test.stub(Proxy, fn conn ->
      send(test_pid, {:outbound_attempt, conn.request_path})
      Plug.Conn.send_resp(conn, 403, ~s({"error":"outbound HTTP is blocked in this test"}))
    end)

    ctx = tenant!()
    opts = [actor: SystemActor.oban(), tenant: ctx.tenant]

    target =
      Task.capture!("Book the follow-up appointment", %{}, actor: ctx.actor, tenant: ctx.tenant)

    ledger =
      Task.capture!("Completion record for the follow-up", %{},
        actor: ctx.actor,
        tenant: ctx.tenant
      )

    %{opts: opts, target: target, ledger: ledger}
  end

  defp events(id) do
    EventLog
    |> Ash.Query.filter(record_id == ^id)
    |> Ash.read!(authorize?: false)
  end

  # The executor's shape: the target's effect, then "succeed", in one transaction.
  defp execute(target, ledger, opts, succeed) do
    Ash.transact([Task], fn ->
      effect = target |> Ash.Changeset.for_update(:complete, %{}, opts) |> Ash.update!()
      succeed.(ledger, opts)
      effect
    end)
  end

  defp succeed(ledger, opts),
    do: ledger |> Ash.Changeset.for_update(:plan_today, %{}, opts) |> Ash.update!()

  test "the effect and its completion commit together, with no outbound call", ctx do
    target_events = length(events(ctx.target.id))

    assert {:ok, %Task{status: :done}} = execute(ctx.target, ctx.ledger, ctx.opts, &succeed/2)

    assert Ash.get!(Task, ctx.target.id, ctx.opts).status == :done
    assert Ash.get!(Task, ctx.ledger.id, ctx.opts).plan == :today
    assert length(events(ctx.target.id)) == target_events + 1
    refute_received {:outbound_attempt, _}
  end

  test "a failed completion rolls the effect and its audit event back; a retry commits once",
       ctx do
    target_events = length(events(ctx.target.id))

    failing = fn ledger, opts ->
      succeed(ledger, opts)
      Ash.DataLayer.rollback(Task, :lease_lost)
    end

    assert {:error, error} = execute(ctx.target, ctx.ledger, ctx.opts, failing)
    assert Exception.message(error) =~ "lease_lost"

    assert Ash.get!(Task, ctx.target.id, ctx.opts).status == :open
    assert Ash.get!(Task, ctx.ledger.id, ctx.opts).plan == :inbox
    assert length(events(ctx.target.id)) == target_events

    assert {:ok, %Task{status: :done}} = execute(ctx.target, ctx.ledger, ctx.opts, &succeed/2)
    assert length(events(ctx.target.id)) == target_events + 1
    refute_received {:outbound_attempt, _}
  end

  test "a hook that calls out inside the transaction is caught before commit", ctx do
    calls_out = fn changeset ->
      Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
        Proxy.request(%{
          method: :post,
          path: "/notify",
          provider_config_key: "spike",
          connection_id: "spike"
        })

        result
      end)
    end

    result =
      Ash.transact([Task], fn ->
        ctx.target
        |> Ash.Changeset.for_update(:complete, %{}, ctx.opts)
        |> calls_out.()
        |> Ash.update!()

        # The hook has already run: the attempt is visible before commit, so
        # the contract test can fail the target here.
        assert_received {:outbound_attempt, "/proxy/notify"}
        Ash.DataLayer.rollback(Task, :outbound_call_in_internal_target)
      end)

    assert {:error, error} = result
    assert Exception.message(error) =~ "outbound_call_in_internal_target"
    assert Ash.get!(Task, ctx.target.id, ctx.opts).status == :open
  end
end

defmodule AshEnterprise.Durability.HarnessTest do
  @moduledoc """
  The durability tier proves its own premise: a process killed between two commits leaves the
  first committed and the second not, anyone can see that, and the retry finishes the work
  without repeating the first commit.

  Each of those is something the sandbox cannot show. There, nothing commits, the test's reads
  share the job's connection, and a job never runs in a process of its own.
  """

  use AshEnterprise.DurabilityCase, async: false

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Durability.TwoCommitWorker
  alias AshEnterprise.Platform.SystemActor

  setup do
    unique = System.unique_integer([:positive])

    organization =
      Organization.create!(
        %{name: "Harness clinic #{unique}", unique_name: "harness-#{unique}"},
        actor: SystemActor.seed()
      )

    subscribe_jobs()

    %{tenant: organization.id}
  end

  describe "a kill between two commits" do
    test "is observable: the first commit stands, the second never happened", %{tenant: tenant} do
      Faults.arm(TwoCommitWorker.fault_point(), :kill, notify: self())

      # The retry held off for a minute, so what is read below is the state the kill left, not
      # a retry already under way.
      job =
        Oban.insert!(
          TwoCommitWorker.new(%{"tenant" => tenant, "code" => "XTS", "retry_in" => 60})
        )

      assert_receive {:fault_fired, _point, job_pid}, 10_000
      meta = await_job(job.id, :failure)

      # The process was killed, not raised out of: nothing in it could clean up or report.
      assert meta.kind == :exit
      assert meta.reason == :killed
      refute Process.alive?(job_pid)

      # Read on the test's own connection, which shares nothing with the dead job's: what is
      # seen here is committed.
      currency = TwoCommitWorker.find(tenant, "XTS")
      assert Decimal.equal?(currency.exchange_rate, TwoCommitWorker.provisional_rate())

      failed = job!(job.id)
      assert failed.state == "retryable"
      assert failed.attempt == 1
      assert [%{"error" => error}] = failed.errors
      assert error =~ "killed"
    end

    test "is recoverable: the retry finishes once, without repeating the first commit", %{
      tenant: tenant
    } do
      Faults.arm(TwoCommitWorker.fault_point(), :kill)

      job = Oban.insert!(TwoCommitWorker.new(%{"tenant" => tenant, "code" => "XTS"}))

      await_job(job.id, :failure)
      opened = TwoCommitWorker.find(tenant, "XTS")

      # The fault was armed for one firing, so the retry Oban schedules runs the real path.
      await_job(job.id, :success)

      settled = TwoCommitWorker.find(tenant, "XTS")
      assert settled.id == opened.id
      assert Decimal.equal?(settled.exchange_rate, TwoCommitWorker.settled_rate())

      assert [_one] =
               AshEnterprise.Reference.Currency.read!(
                 actor: SystemActor.process(),
                 tenant: tenant,
                 authorize?: false
               )

      completed = job!(job.id)
      assert completed.state == "completed"
      assert completed.attempt == 2
    end

    test "a raise at the same point is recorded as the job's error, and also recovers", %{
      tenant: tenant
    } do
      Faults.arm(TwoCommitWorker.fault_point(), :raise)

      job = Oban.insert!(TwoCommitWorker.new(%{"tenant" => tenant, "code" => "XTS"}))

      meta = await_job(job.id, :failure)
      assert %AshEnterprise.Faults.Fault{} = meta.reason

      await_job(job.id, :success)
      assert job!(job.id).state == "completed"
    end
  end

  describe "the harness" do
    test "commits are visible to other connections, and races really overlap", %{tenant: tenant} do
      # Twenty processes, each on its own pooled connection, opening the same currency at
      # once. The identity lets exactly one win; under the sandbox they would share one
      # connection and the race would never happen.
      results =
        race(20, fn _index ->
          AshEnterprise.Reference.Currency.create(
            %{
              iso_currency_code: "XXX",
              currency_name: "Race",
              currency_symbol: "X",
              currency_precision: 0,
              exchange_rate: Decimal.new("1")
            },
            actor: SystemActor.process(),
            tenant: tenant,
            authorize?: false
          )
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 19
    end

    property "interleavings keep each actor's own order, and cover both orders" do
      scripts = %{a: [:claim, :complete], b: [:claim, :complete]}

      check all(order <- Interleavings.interleaving(scripts)) do
        assert length(order) == 4

        for {actor, steps} <- scripts do
          assert for({^actor, step} <- order, do: step) == steps
        end
      end

      firsts =
        scripts
        |> Interleavings.interleaving()
        |> Enum.take(200)
        |> MapSet.new(fn [{first, _step} | _rest] -> first end)

      assert firsts == MapSet.new([:a, :b])
    end

    test "the step runner names the step that broke an invariant" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Interleavings.run([1, 2, 3], 0, &(&1 + &2), fn total -> assert total < 3 end)
        end

      assert error.message =~ "after step 2 of 3: 2"
    end
  end
end

defmodule AshEnterprise.Execution.IdentityTest do
  @moduledoc """
  Invariant 2, stable logical identity (ADR 0055): one key names one request.

  Twenty processes invoke the same request under the same key at the same moment, each
  on its own connection. All but one miss the key, try to insert, and collide on its
  unique identity; each loser reads the key again and gets the winner's row. One row, one
  job, one committed effect. The same key with different arguments is a conflict that
  leaves the first row exactly as it was.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  alias AshAgent.Invocation.IdempotencyConflict

  setup do
    subscribe_jobs()
    clinic!()
  end

  test "twenty concurrent invokes with one key give one row and one execution", %{nurse: nurse} do
    unique = System.unique_integer([:positive])
    key = "identity:#{unique}"
    title = "Call the lab about panel #{unique}"

    count_request_attempts(key)

    results = race(20, fn _ -> invoke(nurse, record_target(), %{"title" => title}, key) end)

    assert Enum.all?(results, &match?({:ok, _row}, &1)), inspect(results)

    # More than one caller missed the key and tried to insert: the losers' path (collide
    # on the identity, read the key again) is what returned their rows.
    assert attempts() > 1
    assert [id] = results |> Enum.map(fn {:ok, row} -> row.id end) |> Enum.uniq()
    assert [%{id: ^id}] = rows(nurse.tenant, key)

    assert [job] = jobs(id)
    await_job(job.id, :success)

    assert [%{status: :succeeded, lease_epoch: 1, attempt_count: 1}] = rows(nurse.tenant, key)
    assert effects(nurse.tenant, title) == 1
  end

  test "the same key with different arguments is a conflict; the first row is unchanged",
       %{nurse: nurse} do
    unique = System.unique_integer([:positive])
    key = "identity:#{unique}"
    title = "Confirm the first appointment #{unique}"

    {:ok, first} = invoke(nurse, record_target(), %{"title" => title}, key)
    [job] = jobs(first.id)
    await_job(job.id, :success)
    [before] = rows(nurse.tenant, key)

    results =
      race(5, fn _ -> invoke(nurse, record_target(), %{"title" => "#{title}, changed"}, key) end)

    for result <- results do
      assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{key: ^key}]}} = result
    end

    assert [after_conflict] = rows(nurse.tenant, key)

    assert Map.take(after_conflict, fields()) == Map.take(before, fields())
    assert effects(nurse.tenant, title) == 1
    assert effects(nurse.tenant, "#{title}, changed") == 0
    assert [_one] = jobs(first.id)
  end

  # Counts the `request` creates started from now on, in any process.
  defp count_request_attempts(key) do
    test = self()
    handler = "identity-test-#{key}"

    :ok =
      :telemetry.attach(
        handler,
        [:ash, :execution, :create, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:action] == :request, do: send(test, :request_attempted)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp attempts(count \\ 0) do
    receive do
      :request_attempted -> attempts(count + 1)
    after
      0 -> count
    end
  end

  defp fields,
    do: [:id, :status, :args_digest, :encrypted_args, :version_number, :lease_epoch, :modified_on]
end

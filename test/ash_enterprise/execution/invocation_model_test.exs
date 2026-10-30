defmodule AshEnterprise.Execution.InvocationModelTest do
  @moduledoc """
  A model test of the invocation lifecycle (ADR 0055): StreamData draws sequences of the
  operations that reach an invocation (a request, a claim, a completion that may be
  stale, a duplicate job delivery, an approval decision, a cancellation) over two keys and
  two workers, and the invariants are checked against committed state after every one.

  Key 0 names a target that needs no approval; key 1 one that a person confirms first.
  Each sequence uses keys and note titles of its own. The `:execution` queue is paused,
  so only the drawn operations act.

  Invariants, per key:

    1. at most one row;
    2. at most one committed effect, and one exactly when the row has succeeded;
    3. a row that reached a terminal state never changes again;
    4. the stored argument digest never changes, and the lease epoch never goes back;
    5. a request is answered with the existing row when its arguments match the first
       request under that key, and with a conflict when they do not.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  require Ash.Query

  alias AshAgent.Invocation.{Executor, IdempotencyConflict}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Test.DailyFixtures

  @terminal [:succeeded, :failed, :rejected, :stale, :cancelled]

  setup do
    pause_execution!()
    clinic!()
  end

  defp operation do
    key = StreamData.integer(0..1)
    worker = StreamData.member_of([:a, :b])

    StreamData.one_of([
      StreamData.tuple({StreamData.constant(:request), key, StreamData.integer(0..1)}),
      StreamData.tuple({StreamData.constant(:claim), key, worker}),
      StreamData.tuple({StreamData.constant(:complete), key, worker}),
      StreamData.tuple({StreamData.constant(:deliver), key}),
      StreamData.tuple(
        {StreamData.constant(:decide), key, StreamData.member_of([:approve, :reject])}
      ),
      StreamData.tuple({StreamData.constant(:cancel), key})
    ])
  end

  property "every interleaving of request, claim, stale completion, delivery, decision and cancel keeps the invariants",
           %{nurse: nurse, tenant: tenant} do
    check all(ops <- Interleavings.commands([operation()], max_length: 12), max_runs: 25) do
      run = System.unique_integer([:positive])

      initial = %{
        run: run,
        nurse: nurse,
        tenant: tenant,
        first_variant: %{},
        answers: [],
        held: %{},
        last: %{}
      }

      # Each step first records the rows as they stand, so the check after it can compare
      # what the step changed.
      Interleavings.run(
        ops,
        initial,
        fn op, state -> apply_op(op, %{state | last: snapshot(state)}) end,
        &invariants/1
      )
    end
  end

  # --- operations ---------------------------------------------------------------------

  defp apply_op({:request, k, variant}, state) do
    target = if k == 0, do: record_target(), else: reviewed_target()
    answer = invoke(state.nurse, target, %{"title" => title(state, k, variant)}, key(state, k))
    first = Map.get(state.first_variant, k)

    state =
      case answer do
        {:ok, _row} when is_nil(first) -> put_in(state, [:first_variant, k], variant)
        _ -> state
      end

    %{state | answers: [{k, variant, answer} | state.answers]}
  end

  defp apply_op({:claim, k, worker}, state) do
    with %{} = row <- row(state, k),
         {:ok, claimed} <- Executor.claim(row, oban(state.tenant), lease_for: 0) do
      put_in(state, [:held, {k, worker}], claimed)
    else
      _ -> state
    end
  end

  defp apply_op({:complete, k, worker}, state) do
    case Map.fetch(state.held, {k, worker}) do
      {:ok, claimed} ->
        {:ok, outcome} = Executor.run_claimed(claimed, oban(state.tenant))
        assert outcome in [:succeeded, :failed, :superseded]
        %{state | held: Map.delete(state.held, {k, worker})}

      :error ->
        state
    end
  end

  defp apply_op({:deliver, k}, state) do
    with %{id: id} <- row(state, k) do
      assert {:ok, outcome} =
               Execution.execute_invocation(%{"id" => id}, oban(state.tenant))

      assert outcome in [:succeeded, :failed, :skipped, :superseded]
    end

    state
  end

  # The requester confirms (or declines) their own request through the task door, and
  # the job runner applies whatever the task says.
  defp apply_op({:decide, k, decision}, state) do
    with %{} = row <- row(state, k) do
      with %{status: :open} = task <- approval_task(row, state.tenant) do
        HumanTask
        |> Ash.ActionInput.for_action(decision, %{record_id: task.id},
          actor: DailyFixtures.actor(state.nurse.user),
          tenant: state.tenant
        )
        |> Ash.run_action()
      end

      Execution.apply_invocation_decision(row, oban(state.tenant))
    end

    state
  end

  defp apply_op({:cancel, k}, state) do
    with %{} = row <- row(state, k) do
      Execution.request_invocation_cancel(row, oban(state.tenant))
    end

    state
  end

  defp approval_task(row, tenant) do
    key = Approval.key()
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  # --- invariants ---------------------------------------------------------------------

  defp invariants(state), do: Enum.each([0, 1], &key_invariants(state, &1))

  defp key_invariants(state, k) do
    rows = rows(state.tenant, key(state, k))
    assert length(rows) <= 1

    committed =
      effects(state.tenant, title(state, k, 0)) + effects(state.tenant, title(state, k, 1))

    assert committed <= 1
    check_row(state, k, rows, committed)

    for {^k, variant, answer} <- state.answers do
      check_answer(state, k, variant, answer, rows)
    end
  end

  defp check_row(state, k, [row], committed) do
    assert committed == if(row.status == :succeeded, do: 1, else: 0)
    check_history(state, k, row)
  end

  defp check_row(_state, _k, [], committed), do: assert(committed == 0)

  defp check_history(state, k, row) do
    case Map.get(state.last, k) do
      nil ->
        :ok

      last ->
        assert row.args_digest == last.args_digest
        assert row.lease_epoch >= last.lease_epoch

        if last.status in @terminal do
          assert Map.take(row, [:status, :version_number, :lease_epoch, :failure_class]) ==
                   Map.take(last, [:status, :version_number, :lease_epoch, :failure_class])
        end
    end
  end

  defp check_answer(state, k, variant, answer, [row]) do
    if variant == Map.fetch!(state.first_variant, k) do
      assert {:ok, %{id: id}} = answer
      assert id == row.id
    else
      assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{}]}} = answer
    end
  end

  defp check_answer(_state, _k, _variant, answer, []), do: refute(match?({:ok, _}, answer))

  defp snapshot(state) do
    for k <- [0, 1], row = row(state, k), into: %{}, do: {k, row}
  end

  defp row(state, k), do: state.tenant |> rows(key(state, k)) |> List.first()
  defp key(state, k), do: "model:#{state.run}:#{k}"
  defp title(state, k, variant), do: "Model note #{state.run}-#{k}-#{variant}"
end

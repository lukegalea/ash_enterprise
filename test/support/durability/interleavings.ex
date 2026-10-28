defmodule AshEnterprise.Durability.Interleavings do
  @moduledoc """
  StreamData generators for the orders in which concurrent actors' steps can happen, and a
  runner that checks invariants after every step.

  A race is a claim about *every* order two or more actors' steps can interleave in, and the
  orders that break things are rarely the ones a hand-written test picks. These generators
  produce the orders; StreamData shrinks a failing one towards the simplest order that still
  fails, which is usually "one actor finishes, then the other starts".

      property "a stale completion never overwrites a newer claim" do
        check all order <- Interleavings.interleaving(%{a: [:claim, :complete], b: [:claim, :complete]}) do
          Interleavings.run(order, initial_state(), &apply_step/2, &assert_invariants/1)
        end
      end

  Two shapes:

    * `interleaving/1` — fixed scripts per actor, merged in any order that keeps each actor's
      own steps in sequence. For "A claims, stalls; B claims; A completes late".
    * `commands/2` — an open sequence of operations drawn from generators. For model tests
      that throw requests, duplicate deliveries, decisions and cancellations at a system in
      any combination.
  """

  import ExUnit.Assertions

  @type actor :: term()
  @type step :: {actor(), term()}

  @doc """
  Generates merges of the actors' scripts: lists of `{actor, step}` in which every actor's steps
  appear in their scripted order.

  Shrinks towards running the actors one after another in the map's key order.
  """
  @spec interleaving(%{actor() => [term()]}) :: StreamData.t([step()])
  def interleaving(scripts) when is_map(scripts) do
    queues = scripts |> Enum.sort_by(&elem(&1, 0)) |> Enum.reject(&match?({_, []}, &1))
    total = queues |> Enum.map(fn {_actor, steps} -> length(steps) end) |> Enum.sum()

    # One choice per step. Each choice picks among the actors that still have steps left, by
    # remainder, so any list of non-negative integers is a valid order and the all-zero list,
    # where shrinking ends, is "first actor to completion, then the next".
    StreamData.map(
      StreamData.list_of(StreamData.non_negative_integer(), length: total),
      &merge(queues, &1, [])
    )
  end

  defp merge([], _choices, acc), do: Enum.reverse(acc)

  defp merge(queues, [choice | choices], acc) do
    index = rem(choice, length(queues))
    {actor, [step | rest]} = Enum.at(queues, index)

    queues =
      case rest do
        [] -> List.delete_at(queues, index)
        _ -> List.replace_at(queues, index, {actor, rest})
      end

    merge(queues, choices, [{actor, step} | acc])
  end

  @doc """
  Generates sequences of operations, each drawn from one of `operations`.

  `operations` is a list of generators, one per kind of operation, so a model test says what
  can happen and leaves the order to StreamData. Options: `:min_length` (default 1) and
  `:max_length` (default 20).
  """
  @spec commands([StreamData.t(term())], keyword()) :: StreamData.t([term()])
  def commands(operations, opts \\ []) when is_list(operations) and operations != [] do
    StreamData.list_of(StreamData.one_of(operations),
      min_length: Keyword.get(opts, :min_length, 1),
      max_length: Keyword.get(opts, :max_length, 20)
    )
  end

  @doc """
  Applies `steps` in order to `state` with `apply_step`, calling `check` on the state after each
  one, and returns the final state.

  `check` asserts the invariants; when one fails, the failure names the step that broke it and
  the steps that led there, which is the trace a shrunk counterexample needs to be read.
  """
  @spec run([term()], state, (term(), state -> state), (state -> term())) :: state
        when state: term()
  def run(steps, state, apply_step, check) do
    steps
    |> Enum.with_index()
    |> Enum.reduce(state, fn {step, index}, state ->
      state = apply_step.(step, state)

      try do
        check.(state)
      rescue
        error in [ExUnit.AssertionError] ->
          flunk("""
          invariant broken after step #{index + 1} of #{length(steps)}: #{inspect(step)}

          steps so far:
          #{steps |> Enum.take(index + 1) |> Enum.map_join("\n", &"  #{inspect(&1)}")}

          #{Exception.message(error)}
          """)
      end

      state
    end)
  end
end

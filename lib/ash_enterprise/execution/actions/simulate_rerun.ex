defmodule AshEnterprise.Execution.Actions.SimulateRerun do
  @moduledoc """
  `Intervention.simulate`: what a rerun of one invocation would run now, checked as the
  person asking and without running anything. No invocation is created, so none reaches
  `ready` or beyond.

  The answer, for the recovery surface to state before anyone reruns:

    * `rerunnable` and `refusal`: whether `AshEnterprise.Execution.Recovery` offers a rerun,
      and why not;
    * `target`, and `definition_changed`: whether the target's input schema or effects
      declaration changed since the row was requested (its digest now against the row's);
    * `arguments`: `:valid`, or the messages the recorded arguments fail with against the
      target as it is now (`AshAgent.Invocation.Target.prepare/3`, which reads the subject
      as the person); `:erased` when they were shredded; `:unreadable` when they cannot be
      read;
    * `approval` and `approver_role`: what the rerun would wait for;
    * `reaches_outside` and `idempotent`: whether it calls outside the application again,
      and whether a second call could repeat the first one's effect;
    * `runs_as`: the person asking, whose request the rerun would be.
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.Invocation.{Executor, Target}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Recovery

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, invocation} <-
           Execution.get_invocation(
             input.arguments.invocation_id,
             Keyword.put(opts, :load, [:recorded?])
           ) do
      {:ok, preview(invocation, opts, context.actor)}
    end
  end

  defp preview(invocation, opts, actor) do
    rerun = Recovery.rerun(invocation)

    base = %{
      invocation_id: invocation.id,
      target: invocation.target,
      rerunnable: rerun == :ok,
      refusal: refusal(rerun),
      runs_as: actor && Map.get(actor, :id)
    }

    case Target.resolve(invocation.target) do
      {:ok, target} ->
        Map.merge(base, %{
          resolves: true,
          definition_changed: Target.digest(target) != invocation.target_digest,
          arguments: arguments(target, invocation, opts),
          approval: target.effect.approval,
          approver_role: target.effect.approver_role,
          reaches_outside: target.effect.open_world? != false,
          idempotent: target.effect.idempotent? == true
        })

      {:error, message} ->
        Map.merge(base, %{resolves: false, arguments: [message]})
    end
  end

  defp refusal(:ok), do: nil
  defp refusal({:error, reason}), do: Recovery.explain(reason)

  defp arguments(_target, %{recorded?: recorded?}, _opts) when recorded? != true, do: :erased

  defp arguments(target, invocation, opts) do
    case Target.prepare(target, Executor.stored_args(invocation, opts), opts) do
      {:ok, _prepared} -> :valid
      # One message per input at fault, as the recovery page states them
      # (`prepare/3` returns error maps: `message`, and `path` when known).
      {:error, errors} -> Enum.map(errors, & &1.message)
    end
  rescue
    _unreadable -> :unreadable
  end
end

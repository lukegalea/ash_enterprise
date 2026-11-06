defmodule AshEnterprise.Execution.Changes.Rerun do
  @moduledoc """
  `Invocation.rerun`'s work before `request`'s: the row named by `of`, read as the actor,
  gives the new request its target and its arguments, and a new key, `rerun:<id>:<uuid>`;
  the new row names it as `rerun_of_id`. Everything after that is an ordinary request:
  routed, digested, bound to an approval when its declaration asks for one, and run as
  the actor.

  Refused, with nothing written, when the actor cannot read the row, when its arguments
  were erased, when the caller passes arguments of their own (a rerun runs what was
  asked), or when `AshEnterprise.Execution.Recovery.rerun/1` refuses it: an unknown
  outcome, an unfinished row, a run's or process's call.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Recovery

  @impl true
  def change(changeset, _opts, context) do
    opts = context |> Ash.Context.to_opts() |> Keyword.put(:tenant, changeset.tenant)

    with :ok <- no_arguments_of_its_own(changeset),
         {:ok, original} <- original(Ash.Changeset.get_argument(changeset, :of), opts),
         :ok <- rerunnable(original),
         {:ok, args} <- args(original, opts) do
      changeset
      |> Ash.Changeset.force_change_attributes(%{
        target: original.target,
        invocation_key: "rerun:#{original.id}:#{Ash.UUID.generate()}",
        rerun_of_id: original.id
      })
      |> Ash.Changeset.set_argument(:args, args)
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp no_arguments_of_its_own(changeset) do
    case Ash.Changeset.fetch_argument(changeset, :args) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, _args} -> {:error, :args, "a rerun runs the arguments that were asked for"}
    end
  end

  defp original(nil, _opts), do: {:error, :of, "is required"}

  defp original(id, opts) do
    case Execution.get_invocation(id, Keyword.put(opts, :load, [:recorded?])) do
      {:ok, row} -> {:ok, row}
      {:error, _not_readable} -> {:error, :of, "no invocation you can read has this id"}
    end
  end

  defp rerunnable(original) do
    case Recovery.rerun(original) do
      :ok -> :ok
      {:error, reason} -> {:error, :of, "cannot be rerun: " <> Recovery.explain(reason)}
    end
  end

  defp args(%{recorded?: true} = original, opts) do
    {:ok, Executor.stored_args(original, opts)}
  rescue
    _unreadable -> {:error, :of, "cannot be rerun: its arguments cannot be read"}
  end

  defp args(_original, _opts), do: {:error, :of, "cannot be rerun: its arguments were erased"}
end

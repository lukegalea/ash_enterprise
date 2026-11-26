defmodule AshEnterprise.Documents.Paper.SealingScope do
  @moduledoc """
  Which erasure scope a run's sealed content goes under: the scope of the
  person the document is about, when its kind names one.

  A run's `payload`, `facts` and `payload_hash_key` are what the document
  said, so they belong to the person it said it about. A kind that knows who
  that is implements the optional `sealing_scope/2` callback
  (`AshEnterprise.Documents.Paper.Kind`): given the subject, read as the actor
  the way `source/2` reads its rows, it returns `{:ok, scope_id}`, and
  shredding that scope erases what every document about them said and, by
  the refcount in `AshEnterprise.Documents.Paper.Changes.ShredDocuments`, the
  bytes no run in a surviving scope still shares.

  A kind that does not implement it is sealed exactly as before, under the
  requester's own `data_subject` scope
  (`AshEnterprise.Planning.Changes.ScopeAndOwner`, `from: :requester`). Either
  way the requester owns the run and reads it through their owner grants: only
  the sealing scope moves.

  There is no fallback. A scope the kind names must exist and be live; a
  scope that is shredded or not found, a callback that returns an error, or a
  return that names no scope refuses the issue before any run row exists.
  Content is never sealed under a guessed scope, and never under the
  requester's because the kind's answer failed.

  The scope row is read without authorization: which key seals a run is the
  issue's bookkeeping, not a read on anyone's behalf. The kind's own read, the
  one that decides whose scope it is, is the actor's.
  """

  require Ash.Query

  alias AshEnterprise.Erasure.Scope

  @doc """
  The scope `kind_module` seals a run for `subject` under: `{:ok, nil}` when
  the kind names none (the requester's scope, as `ScopeAndOwner` resolves it),
  `{:ok, scope_id}` for a live scope it names, or `{:error, reason}`:
  `{:unavailable, reason}` from the kind, `{:not_found, id}`,
  `{:shredded, id}` or `{:invalid, returned}`.
  """
  @spec resolve(module(), map(), keyword()) :: {:ok, Ecto.UUID.t() | nil} | {:error, term()}
  def resolve(kind_module, subject, opts) do
    if names_scope?(kind_module) do
      kind_module.sealing_scope(subject, Keyword.take(opts, [:actor, :tenant]))
      |> named()
    else
      {:ok, nil}
    end
  end

  @doc "Whether `kind_module` implements the optional `sealing_scope/2` callback."
  @spec names_scope?(module()) :: boolean()
  def names_scope?(kind_module) do
    Code.ensure_loaded?(kind_module) and function_exported?(kind_module, :sealing_scope, 2)
  end

  defp named({:ok, scope_id}) when is_binary(scope_id) do
    case Ecto.UUID.cast(scope_id) do
      {:ok, id} -> live(id)
      :error -> {:error, {:invalid, scope_id}}
    end
  end

  defp named({:error, reason}), do: {:error, {:unavailable, reason}}
  defp named(other), do: {:error, {:invalid, other}}

  defp live(id) do
    Scope
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :status])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Scope{status: :active}} -> {:ok, id}
      {:ok, %Scope{}} -> {:error, {:shredded, id}}
      {:ok, nil} -> {:error, {:not_found, id}}
      {:error, error} -> {:error, {:unavailable, error}}
    end
  end
end

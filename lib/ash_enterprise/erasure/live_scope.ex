defmodule AshEnterprise.Erasure.LiveScope do
  @moduledoc """
  Run derived writes only while their erasure scopes are live, serialized
  against a shred.

  A projector writes rows that are not sealed under a scope (`Canonical.Person`
  names and emails) next to rows that are. The sealed writes are refused once
  the scope is shredded (`SealUnderScope` rechecks under a `FOR SHARE` lock),
  but the plain ones are not: a shred that commits between a landing and its
  projection would otherwise still get new plaintext rows derived from the
  content it just destroyed.

  `run/2` opens a transaction, takes a `FOR SHARE` lock on each scope row and
  reads its status, then calls `fun` with the set of scope ids that are live.
  `Scope.shred` updates the scope row, so it waits for this transaction (and
  this one waits for a shred already in flight): a shred either reaches every
  row the projection wrote, or the projection sees the scope shredded and
  writes nothing derived from it. `fun` returning `{:error, _}` rolls back.

      LiveScope.run([scope_id], fn live ->
        if MapSet.member?(live, scope_id), do: write_everything(), else: {:ok, :shredded}
      end)
  """

  require Ash.Query

  alias AshEnterprise.Erasure.LiveScope.Aborted
  alias AshEnterprise.Erasure.Scope

  @doc """
  Lock `scope_ids` and call `fun.(live_scope_ids)` inside one transaction.
  Returns `{:ok, value}` for a `fun` returning `{:ok, value}` (or any other
  value), and `{:error, reason}`, rolled back, for one returning
  `{:error, reason}`.
  """
  @spec run([Ash.UUID.t()], (MapSet.t() -> term())) :: {:ok, term()} | {:error, term()}
  def run(scope_ids, fun) when is_list(scope_ids) and is_function(fun, 1) do
    ids = scope_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

    Scope
    |> Ash.transact(fn -> ids |> lock_live() |> fun.() |> carry() end)
    |> unwrap()
  end

  defp lock_live(ids) do
    Scope
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(:id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.status == :active))
    |> MapSet.new(& &1.id)
  end

  # `Ash.transact/3` turns an `{:error, reason}` into an Ash error class; the
  # reason rides through it inside `Aborted` and comes back out in `unwrap/1`.
  defp carry({:ok, value}), do: {:ok, value}
  defp carry({:error, reason}), do: {:error, Aborted.exception(reason: reason)}
  defp carry(value), do: {:ok, value}

  defp unwrap({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap({:ok, value}), do: {:ok, value}

  defp unwrap({:error, error}) do
    case Aborted.unwrap(error) do
      {:ok, reason} -> {:error, reason}
      :error -> {:error, error}
    end
  end
end

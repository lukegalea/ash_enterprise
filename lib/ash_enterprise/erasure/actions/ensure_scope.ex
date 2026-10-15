defmodule AshEnterprise.Erasure.Actions.EnsureScope do
  @moduledoc """
  `Scope.ensure`: the scope for `(kind, ref)`, opened the first time it is asked
  for.

  Look-up first, open second, and look up again if the open lost a race to a
  concurrent ensure for the same `(kind, ref)` — the `unique_scope` identity is
  what decides the race, so two adapters starting at once still end up sharing
  one scope and one key rather than holding two.

  A shredded scope is returned as it is. Reopening it would issue a new key to
  a scope whose old ciphertext is meant to stay unreadable, and new content
  under the same `ref` would then look continuous with content that was erased.
  `AshEnterprise.Erasure.Keyring.seal/2` refuses to seal under it, so the
  caller finds out at its first write.

  The actor, tenant and authorization flag of the generic action are passed
  through to the read and the create, so `ensure` is exactly as authorized as
  calling `by_ref` and then `open` yourself.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)
    kind = input.arguments.kind
    ref = input.arguments.ref
    label = Map.get(input.arguments, :label)

    case Erasure.scope_by_ref(kind, ref, opts) do
      {:ok, %Scope{} = scope} -> {:ok, scope}
      {:ok, nil} -> open(kind, ref, label, opts)
      {:error, error} -> {:error, error}
    end
  end

  defp open(kind, ref, label, opts) do
    case Erasure.open_scope(%{kind: kind, ref: ref, label: label}, opts) do
      {:ok, scope} -> {:ok, scope}
      {:error, error} -> lost_race(error, kind, ref, opts)
    end
  end

  # A concurrent ensure opened the same `(kind, ref)` first: use its scope.
  defp lost_race(error, kind, ref, opts) do
    with true <- identity_conflict?(error),
         {:ok, %Scope{} = scope} <- Erasure.scope_by_ref(kind, ref, opts) do
      {:ok, scope}
    else
      _ -> {:error, error}
    end
  end

  defp identity_conflict?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{private_vars: vars} when is_list(vars) ->
        Keyword.get(vars, :constraint_type) == :unique

      %Ash.Error.Changes.InvalidAttribute{message: message} when is_binary(message) ->
        message =~ "already been taken"

      _ ->
        false
    end)
  end

  defp identity_conflict?(_error), do: false
end

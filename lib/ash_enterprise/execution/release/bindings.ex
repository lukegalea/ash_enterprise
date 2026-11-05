defmodule AshEnterprise.Execution.Release.Bindings do
  @moduledoc """
  What promoting a manifest does to `AshEnterprise.Process.Binding`, the one pinning
  mechanism for processes and decisions: each `process` and `decision` entry is bound for
  the tenant to the exact definition the manifest pinned, and an entry of the manifest it
  replaces that the new one does not name is unbound, so the key follows its baseline again.

  An entry whose definition the tenant owns binds with `source: :tenant`; one that is the
  platform baseline binds with `source: :platform`, held at the pinned version.
  """

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Binding

  @kinds ["process", "decision"]

  @doc "Binds `entries` in `tenant`, and unbinds the entries of `replaced` they do not name."
  @spec apply!([map()], [map()], Ash.UUID.t()) :: :ok
  def apply!(entries, replaced, tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]
    bound = for e <- entries, bindable?(e), do: e

    for entry <- bound do
      kind = String.to_existing_atom(entry["annotations"]["kind"])

      Binding.bind!(
        %{
          kind: kind,
          key: entry["name"],
          source: source(entry, tenant),
          target_id: entry["annotations"]["id"],
          bound_version: entry["annotations"]["version"]
        },
        opts
      )
    end

    named = MapSet.new(bound, &{&1["annotations"]["kind"], &1["name"]})

    for old <- replaced, bindable?(old), {old["annotations"]["kind"], old["name"]} not in named do
      kind = String.to_existing_atom(old["annotations"]["kind"])

      case Binding.by_key(kind, old["name"], Keyword.put(opts, :not_found_error?, false)) do
        {:ok, %Binding{} = binding} -> Binding.unbind!(binding, opts)
        _unbound_already -> :ok
      end
    end

    :ok
  end

  defp bindable?(%{"annotations" => %{"kind" => kind}}), do: kind in @kinds

  # A definition the tenant has no row for is the platform's.
  defp source(entry, tenant) do
    kind = String.to_existing_atom(entry["annotations"]["kind"])

    case AshEnterprise.Process.Resolver.owned?(kind, entry["annotations"]["id"], tenant) do
      true -> :tenant
      false -> :platform
    end
  end
end

defmodule AshEnterprise.Bpmn.Calculations.ProcessName do
  @moduledoc """
  The name of the process an instance runs, with its version: `Morning brief
  v1`, or `Unknown process` when its definition cannot be found.

  The definition is the one the instance **pinned**, found wherever it lives
  (`AshEnterprise.Process.DefinitionLoader`): the tenant's own copy, or the
  platform baseline most instances run, which a tenant-scoped read cannot
  see. A definition is configuration — what the process looks like, never
  what it is about — so this reads it with the loader's authority. The
  instance itself was read under the reader's policies.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Process.DefinitionLoader

  @impl true
  def load(_query, _opts, _context), do: [:definition_id, :organization_id]

  @impl true
  def calculate(instances, _opts, _context) do
    names =
      instances
      |> Enum.uniq_by(& &1.definition_id)
      |> Map.new(&{&1.definition_id, name(&1)})

    {:ok, Enum.map(instances, &Map.fetch!(names, &1.definition_id))}
  end

  defp name(instance) do
    case DefinitionLoader.load(
           AshEnterprise.Bpmn.Definition,
           instance.definition_id,
           instance,
           %{tenant: instance.organization_id}
         ) do
      {:ok, definition} -> "#{definition.name || definition.key} v#{definition.version}"
      {:error, _not_found} -> "Unknown process"
    end
  end
end

defmodule AshEnterprise.Bpmn.Subscription.Validations.HumanTasksOnly do
  @moduledoc """
  Refuses to publish a `:human_tasks_only` subscription whose process acts on its own.

  Reads the compiled graph of the process the subscription names (the latest published
  version of `process_key` in the tenant, the one the sweep would start) and refuses any
  service, send or script task, or call activity, naming each.

  What publish cannot see is checked when the process runs instead: a process published
  later under the same key, or one a decision route picks, that reaches a service task runs
  nothing (`AshEnterprise.Process.RecipeAuthority`). So a key with nothing published yet
  is not refused here.

  A validation, not a policy check: it reads the graph snapshot as the platform's process
  actor, the way the sweep does.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def validate(changeset, _opts, _context) do
    with :human_tasks_only <- Ash.Changeset.get_attribute(changeset, :authority),
         key when is_binary(key) <- Ash.Changeset.get_attribute(changeset, :process_key),
         [_ | _] = acting <- acting_nodes(key, changeset.tenant) do
      {:error,
       field: :authority,
       message:
         "a human-tasks-only recipe cannot start #{key}: its diagram has steps that act " <>
           "on their own (#{name_nodes(acting)}); only user tasks, decisions, gateways and " <>
           "events may run"}
    else
      _ -> :ok
    end
  end

  defp acting_nodes(key, tenant) do
    case Definition.latest_published(key, actor: SystemActor.process(), tenant: tenant) do
      {:ok, [definition | _]} -> Authority.acting_nodes(definition.graph)
      _ -> []
    end
  end

  defp name_nodes(nodes), do: Enum.map_join(nodes, ", ", fn {id, type} -> "#{type} #{id}" end)
end

defmodule AshEnterprise.Execution.Actions.StartProcess do
  @moduledoc """
  `StartProcess.start`: starts the instance, as the person the invocation runs for.

  The record is read as that person, so one they cannot read is the same refusal as one
  that does not exist. The instance is started in the invocation's transaction.

  An agent whose runs execute as an automation principal starts nothing: the instance
  records only the person who started it, and its governed tasks run as that person's whole
  authority, which is more than the principal acting for them holds (the intersection rule,
  ADR 0043). Recording the principal on the instance, so its tasks run on the same
  intersection, is what would lift this.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Process.Resolver

  @impl true
  def run(_input, _opts, %{actor: %AutomationPrincipal{}}),
    do:
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :process,
         message: "cannot be started by an agent that runs as an automation principal"
       )}

  def run(input, _opts, context) do
    %{process: key, subject_type: type, subject_id: id} = input.arguments
    opts = Ash.Context.to_opts(context)

    with {:ok, subject} <- subject(type, id, opts),
         {:ok, definition} <- Resolver.resolve(:process, key, context.tenant),
         {:ok, instance} <-
           AshBpmn.start_instance(AshEnterprise.Bpmn,
             definition: definition,
             subject: subject,
             actor: context.actor,
             started_by_id: context.actor.id,
             tenant: context.tenant
           ) do
      {:ok, %{"instance_id" => instance.id, "process" => key, "version" => definition.version}}
    end
  end

  defp subject(type, id, opts) do
    with {:ok, resource} <- resource(type),
         {:ok, %{} = subject} <- Ash.get(resource, id, opts) do
      {:ok, subject}
    else
      _unreachable -> {:error, not_found()}
    end
  end

  # Only a module that is already loaded can be named, and only an Ash resource.
  defp resource(type) do
    module = String.to_existing_atom("Elixir." <> type)

    if Ash.Resource.Info.resource?(module), do: {:ok, module}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp not_found,
    do:
      Ash.Error.Changes.InvalidArgument.exception(
        field: :subject_id,
        message: "the record to start the process on was not found"
      )
end

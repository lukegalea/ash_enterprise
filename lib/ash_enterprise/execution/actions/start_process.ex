defmodule AshEnterprise.Execution.Actions.StartProcess do
  @moduledoc """
  `StartProcess.start`: starts the instance, as the person the invocation runs for.

  The record is read as that person, so one they cannot read is the same refusal as one
  that does not exist. The instance is started in the invocation's transaction.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Process.Resolver

  @impl true
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

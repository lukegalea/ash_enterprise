defmodule AshEnterprise.Integration.Nango.RunOperation do
  @moduledoc """
  The run step of every generated provider action.

  1. Resolve the connection from the **actor**: the actor's own active linked
     account for the resource's integration (`LinkedAccount.for_operation`),
     read under the actor's policies and the actor's tenant. A
     `linked_account_id` argument narrows the choice to one of those rows; it
     cannot reach outside them.
  2. Build the request from the declared operation and the arguments.
  3. Proxy it through `AshEnterprise.Integration.Nango.Proxy`.

  Returns `{:ok, body}` — the provider's decoded JSON — or
  `{:error, %AshEnterprise.Integration.ProxyError{}}`.

  Non-human actors resolve no connection (`:no_linked_account`): a system
  actor bypasses the operation's policy but owns no linked account, so it can
  never spend a person's credentials.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Integration.Nango.{Info, Proxy, Request}
  alias AshEnterprise.Integration.ProxyError
  alias AshEnterprise.Security.ActorContext

  @impl true
  def run(input, opts, context) do
    resource = input.resource
    operation = Info.operation(resource, Keyword.fetch!(opts, :operation))
    integration = Info.integration(resource)

    with {:ok, account} <-
           resolve(integration, Map.get(input.arguments, :linked_account_id), context, operation),
         {:ok, request} <- build(operation, input.arguments, integration),
         {:ok, %{body: body}} <-
           Proxy.request(
             Map.merge(request, %{
               provider_config_key: account.provider_config_key,
               connection_id: account.connection_id
             }),
             profile: Info.errors(resource),
             operation: operation.name,
             numbers: operation.numbers
           ) do
      {:ok, body}
    end
  end

  defp resolve(integration, linked_account_id, context, operation) do
    actor_context = ActorContext.for_actor(context.actor)

    if is_nil(actor_context.user_id) or is_nil(actor_context.organization_id) do
      {:error, edge_error(:no_linked_account, integration, operation)}
    else
      opts =
        context
        |> Ash.Context.to_opts()
        |> Keyword.put(:tenant, actor_context.organization_id)

      case LinkedAccount.for_operation(integration, linked_account_id, opts) do
        {:ok, [account]} -> {:ok, account}
        {:ok, []} -> {:error, edge_error(:no_linked_account, integration, operation)}
        {:ok, [_ | _]} -> {:error, edge_error(:ambiguous_linked_account, integration, operation)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp build(operation, arguments, integration) do
    case Request.build(operation, arguments) do
      {:ok, request} -> {:ok, request}
      {:error, _message} -> {:error, edge_error(:bad_request, integration, operation)}
    end
  end

  defp edge_error(reason, integration, operation) do
    ProxyError.exception(reason: reason, integration: integration, operation: operation.name)
  end
end

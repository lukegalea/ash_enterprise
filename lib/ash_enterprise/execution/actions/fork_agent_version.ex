defmodule AshEnterprise.Execution.Actions.ForkAgentVersion do
  @moduledoc """
  `fork_for_tenant`: copies the latest platform baseline of a key into the caller's
  tenant as a draft, under the code sync's rule
  (`AshAgent.AgentVersion.Actions.RegisterFromCode.register/3`): when the tenant's
  latest version already holds the baseline's content, that version is returned and
  nothing is written. The copy keeps the baseline's `source` and records it as
  `baseline_id`; the tenant numbers its own versions, so platform version 5 may be the
  tenant's version 1.

  The baseline is read through `AshEnterprise.Process.Resolver.agent_baseline/1`, the
  one named cross-tenant read, and the draft is written as the caller in their tenant.
  Publishing it is the tenant's own request (`request_publish`).
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.AgentVersion.Actions.RegisterFromCode
  alias AshEnterprise.Process.Resolver

  @impl true
  def run(input, _opts, context) do
    case Resolver.agent_baseline(input.arguments.key) do
      {:ok, baseline} ->
        content =
          baseline
          |> Map.take([:key, :source | AshAgent.AgentVersion.content_attributes()])
          |> Map.put(:baseline_id, baseline.id)

        RegisterFromCode.register(input.resource, content, Ash.Context.to_opts(context))

      {:error, reason} ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :key,
           message: "no platform baseline to fork: #{inspect(reason)}"
         )}
    end
  end
end

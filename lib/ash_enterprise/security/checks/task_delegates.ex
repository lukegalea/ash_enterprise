defmodule AshEnterprise.Security.Checks.TaskDelegates do
  @moduledoc """
  A grant path for the delegate picker: **the person holding a task may see
  whom it can be handed to.**

  Authorizes the user reads the resource lists in `reads:`
  (`AshEnterprise.Accounts.User.delegate_candidates`), for a `task_id` among
  the actor's precomputed `AshEnterprise.Security.ActorContext` `task_ids`.
  The read narrows itself to that task's delegates and returns nothing unless
  the actor holds it (`AshEnterprise.Accounts.Preparations.DelegateCandidates`),
  so what this path reaches is the candidate set of a task the person was
  already asked to act on — never a way to browse people. Without it a holder
  with no grant on users (a Data Steward holds none) gets an empty picker.

  Nothing else: no other user read, and no write. Declared on the resource
  that needs it (`extra_grants:` on `AshEnterprise.Platform.Resource`; only
  `AshEnterprise.Accounts.User`) and appended to the inherited union, so it
  only ever adds.

  ## Never queries

  The task id is the read's own argument and `task_ids` is computed once per
  request; the check is a list membership test.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(opts) do
    "the read is #{Enum.map_join(Keyword.get(opts, :reads, []), ", ", &inspect/1)} " <>
      "for a task the actor is asked to act on"
  end

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> false
      is_nil(context.user_id) -> false
      authorizer.action.type != :read -> false
      authorizer.action.name not in Keyword.get(opts, :reads, []) -> false
      true -> task_argument(authorizer) in context.task_ids
    end
  end

  defp task_argument(%{query: %Ash.Query{} = query}), do: Ash.Query.get_argument(query, :task_id)
  defp task_argument(_authorizer), do: nil
end

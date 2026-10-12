defmodule AshEnterprise.Bpmn.Preparations.AwaitingActor do
  @moduledoc """
  Narrows a human-task read to the tasks waiting on the actor: open or claimed,
  with a candidate row naming the actor or one of their teams — the same
  materialised candidacy `/app/tasks` joins on (manifesto 03), oldest first so
  a numbered list stays stable between reads ("approve 1").

  The actor's principal ids are the precomputed `ActorContext`'s (never
  queried for). They are read in a `before_action` hook, i.e. from the actor
  the read actually *runs* as: ash_a2ui builds a table's first query without
  an actor and passes it only to `Ash.read/2`, so anything decided at
  `for_read/4` time would see nobody. No actor, no tasks.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Security.ActorContext

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(status in [:open, :claimed])
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.before_action(fn query ->
      principal_ids = ActorContext.for_actor(running_actor(query)).principal_ids
      Ash.Query.filter(query, exists(candidates, principal_id in ^principal_ids))
    end)
  end

  @doc false
  def running_actor(query), do: get_in(query.context, [:private, :actor])
end

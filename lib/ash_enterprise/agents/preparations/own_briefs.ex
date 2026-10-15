defmodule AshEnterprise.Agents.Preparations.OwnBriefs do
  @moduledoc """
  Narrows a brief read to the running actor's own briefs, most recent first,
  one row — what the Today surface leads with.

  The owner is read in a `before_action` hook, from the actor the read runs
  as (ash_a2ui passes the actor only to `Ash.read/2` on a table's first load,
  so a filter decided at `for_read/4` would see nobody). No actor, no brief.
  Never queries.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.sort(brief_date: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.before_action(fn query ->
      owner_id =
        case AshEnterprise.Bpmn.Preparations.AwaitingActor.running_actor(query) do
          %{id: id} -> id
          _none -> nil
        end

      Ash.Query.filter(query, owner_id == ^owner_id and not is_nil(^owner_id))
    end)
  end
end

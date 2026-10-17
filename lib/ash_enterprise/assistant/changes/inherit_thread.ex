defmodule AshEnterprise.Assistant.Changes.InheritThread do
  @moduledoc """
  An appended turn belongs to a thread the actor may read, and is sealed
  under that thread's scope.

  Reads the thread **as the actor** (an authorized read, so another
  person's thread is simply not found) and copies its `erasure_scope_id`
  onto the turn. A change may query; a policy check may not, which is why
  this is not a policy. Runs in `change/3` because the seal that follows
  needs the scope id there.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Assistant.Thread

  @impl true
  def change(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :thread_id) do
      nil ->
        changeset

      thread_id ->
        opts = Ash.Context.to_opts(context, tenant: changeset.tenant)

        Thread
        |> Ash.Query.filter(id == ^thread_id)
        |> Ash.read_one(opts)
        |> case do
          {:ok, %Thread{erasure_scope_id: scope_id}} ->
            Ash.Changeset.force_change_attribute(changeset, :erasure_scope_id, scope_id)

          _not_readable ->
            Ash.Changeset.add_error(changeset,
              field: :thread_id,
              message: "is not a thread of yours"
            )
        end
    end
  end
end

defmodule AshEnterprise.Bpmn.Dispatch.RecordCause do
  @moduledoc """
  Records on a dispatch who caused the event it answered: the person the started instance
  names as `started_by_id`, which the engine takes from the event's actor.

  The cause is provenance and never authority. Who a recipe's steps run as comes from the
  subscription's `authority` (ADR 0069): a standing grant runs them for the person who
  published the recipe, whoever caused the event. A dispatch that started nothing names no
  cause.

  Reads the instance written earlier in the same transaction, without authorization: this is
  the dispatch row being written, not a policy check.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Bpmn.Instance

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :instance_id) do
        id when is_binary(id) ->
          Ash.Changeset.force_change_attribute(
            changeset,
            :caused_by_id,
            started_by(id, changeset.tenant)
          )

        _no_instance ->
          changeset
      end
    end)
  end

  defp started_by(id, tenant) do
    Instance
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :started_by_id])
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, %Instance{started_by_id: started_by_id}} -> started_by_id
      _none -> nil
    end
  end
end

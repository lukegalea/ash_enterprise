defmodule AshEnterprise.Execution.Validations.OwnsParent do
  @moduledoc """
  A request may name only a parent its requester owns (ADR 0055, "Does it consume
  ActorContext?"): a parent invocation they requested, or a process instance they
  started. Without it, calling `request` directly, past `invoke`, could attach a request
  to someone else's work and inherit its lineage.

  Agent runs do not exist yet, so a request naming a `run_id` is refused rather than
  recorded unchecked.

  This is action logic, so it may read: it reads the parent without authorization and
  compares its owner with the actor. A parent that does not exist and one owned by
  someone else are refused alike.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias AshEnterprise.Bpmn.Instance

  @impl true
  def validate(changeset, _opts, context) do
    actor_id = actor_id(context.actor)

    [
      parent_invocation(changeset, actor_id),
      process_instance(changeset, actor_id),
      run(changeset)
    ]
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp parent_invocation(changeset, actor_id) do
    case Ash.Changeset.get_attribute(changeset, :parent_invocation_id) do
      nil ->
        :ok

      id ->
        changeset.resource
        |> Ash.Query.filter(id == ^id and owner_id == ^actor_id)
        |> Ash.exists?(tenant: changeset.tenant, authorize?: false)
        |> refuse_unless(:parent_invocation_id)
    end
  end

  defp process_instance(changeset, actor_id) do
    case Ash.Changeset.get_attribute(changeset, :process_instance_id) do
      nil ->
        :ok

      id ->
        Instance
        |> Ash.Query.filter(id == ^id and started_by_id == ^actor_id)
        |> Ash.exists?(tenant: changeset.tenant, authorize?: false)
        |> refuse_unless(:process_instance_id)
    end
  end

  defp run(changeset) do
    case Ash.Changeset.get_attribute(changeset, :run_id) do
      nil -> :ok
      _id -> {:error, field: :run_id, message: "agent runs do not exist yet"}
    end
  end

  defp refuse_unless(true, _field), do: :ok

  defp refuse_unless(false, field),
    do: {:error, field: field, message: "names work the requester does not own"}

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_actor), do: nil
end

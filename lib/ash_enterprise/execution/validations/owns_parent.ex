defmodule AshEnterprise.Execution.Validations.OwnsParent do
  @moduledoc """
  A request may name only a parent its requester owns (ADR 0055, "Does it consume
  ActorContext?"): a parent invocation they requested, a process instance they started,
  or an agent run they started (`AshEnterprise.Execution.Run`; a run's tool calls are
  requested as the person who started it). Without it, calling `request` directly, past
  `invoke`, could attach a request to someone else's work and inherit its lineage, or
  wake someone else's run.

  This is action logic, so it may read: it reads the parent without authorization and
  compares its owner with the actor. A parent that does not exist and one owned by
  someone else are refused alike.

  A step of a process a standing-grant recipe started is requested by the person who
  published that recipe version, not by whoever started the instance (ADR 0069), so such a
  request may name the instance too, and only when it asks as that version's recipe runner
  (`AshEnterprise.Process.RecipeAuthority.runs_for?/3`).
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias AshEnterprise.Bpmn.Instance
  alias AshEnterprise.Execution.Run
  alias AshEnterprise.Process.RecipeAuthority

  @impl true
  def validate(changeset, _opts, context) do
    actor_id = actor_id(context.actor)

    [
      parent_invocation(changeset, actor_id),
      process_instance(changeset, actor_id, context.actor),
      run(changeset, actor_id)
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

  defp process_instance(changeset, actor_id, actor) do
    case Ash.Changeset.get_attribute(changeset, :process_instance_id) do
      nil ->
        :ok

      id ->
        started? =
          Instance
          |> Ash.Query.filter(id == ^id and started_by_id == ^actor_id)
          |> Ash.exists?(tenant: changeset.tenant, authorize?: false)

        refuse_unless(
          started? or RecipeAuthority.runs_for?(id, changeset.tenant, actor),
          :process_instance_id
        )
    end
  end

  defp run(changeset, actor_id) do
    case Ash.Changeset.get_attribute(changeset, :run_id) do
      nil ->
        :ok

      id ->
        Run
        |> Ash.Query.filter(id == ^id and owner_id == ^actor_id)
        |> Ash.exists?(tenant: changeset.tenant, authorize?: false)
        |> refuse_unless(:run_id)
    end
  end

  defp refuse_unless(true, _field), do: :ok

  defp refuse_unless(false, field),
    do: {:error, field: field, message: "names work the requester does not own"}

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_actor), do: nil
end

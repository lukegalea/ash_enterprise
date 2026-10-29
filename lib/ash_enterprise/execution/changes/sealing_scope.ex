defmodule AshEnterprise.Execution.Changes.SealingScope do
  @moduledoc """
  Names the erasure scope an invocation's `args` and `result` are sealed under, before
  `AshEnterprise.Erasure.Changes.SealUnderScope` seals them (ADR 0024).

    * **The subject's scope**, when the target acts on a record that is sealed under one
      (an update or destroy of a row with an `erasure_scope_id`). The arguments are about
      that record, so shredding it shreds them too.
    * **Otherwise the requester's own scope** (`data_subject`, ref
      `invocation_requester:<user id>`, an opaque id): the person typed the arguments, so
      they are that person's data.

  The scope is opened by the system actor, as other scope openers do: a tenant role
  cannot write `AshEnterprise.Erasure.Scope`, and opening one says nothing about content.
  A shredded scope is never reopened, so a request whose scope is shredded is refused
  rather than stored unsealed or under some other key.

  The fragment's `request` change runs first and leaves the resolved target and the
  subject in the changeset context under `:ash_agent`. A request it already refused
  carries neither, and this change leaves it alone.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.SystemActor

  @label "Requested actions"

  @impl true
  def change(changeset, _opts, context) do
    if changeset.valid? do
      case scope(changeset, context.actor) do
        {:ok, scope_id} ->
          Ash.Changeset.force_change_attribute(changeset, :erasure_scope_id, scope_id)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :erasure_scope_id, message: message)
      end
    else
      changeset
    end
  end

  defp scope(changeset, actor) do
    case get_in(changeset.context, [:ash_agent, :subject]) do
      %{erasure_scope_id: scope_id} when is_binary(scope_id) -> {:ok, scope_id}
      _no_scope -> requester_scope(actor)
    end
  end

  defp requester_scope(%{id: id}) when is_binary(id) do
    case Erasure.ensure_scope(:data_subject, scope_ref(id), %{label: @label},
           actor: SystemActor.system()
         ) do
      {:ok, %{status: :active, id: scope_id}} -> {:ok, scope_id}
      {:ok, _shredded} -> {:error, "the requester's erasure scope is shredded"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp requester_scope(_actor), do: {:error, "only a person's request can be sealed"}

  @doc "The scope ref of the person with `user_id`'s requests."
  @spec scope_ref(Ash.UUID.t()) :: String.t()
  def scope_ref(user_id), do: "invocation_requester:#{user_id}"
end

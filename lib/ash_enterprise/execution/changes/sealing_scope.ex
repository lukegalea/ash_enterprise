defmodule AshEnterprise.Execution.Changes.SealingScope do
  @moduledoc """
  Names the erasure scope an invocation's `args` and `result`, or an agent run's `input`
  and `output`, are sealed under, before `AshEnterprise.Erasure.Changes.SealUnderScope`
  seals them (ADR 0024). The rule is the subject's scope, and the subject is the most
  specific record the content is about:

    * **The subject's scope**, when the work acts on, or is about, a record that is
      sealed under one: the record an invocation's update or destroy acts on, or the
      record a run names as its subject (`subject_type`, `subject_id`). The content is
      about that record, so shredding its scope shreds the content too.
    * **For an agent run's tool call with no such subject, its run's scope.** The model
      wrote the arguments from what the run was given and read, so they belong where the
      run's own content is: under the run's subject's scope when it names one.
    * **For a rerun, the scope its original was sealed under**
      (`AshEnterprise.Execution.Changes.Rerun`): its arguments are a copy of the
      original's, typed by whoever asked first, so they are erased with the original's.
      A rerun by someone else is not their data, and must not outlive the first
      requester's erasure under the rerunner's scope.
    * **Otherwise the requester's own scope** (`data_subject`, ref
      `invocation_requester:<user id>`, an opaque id): the person typed the content, so
      it is that person's data.

  The scope is opened by the system actor, as other scope openers do: a tenant role
  cannot write `AshEnterprise.Erasure.Scope`, and opening one says nothing about content.
  A shredded scope is never reopened, so a request whose scope is shredded is refused
  rather than stored unsealed or under some other key.

  The fragment's `request` and `start` changes run first and leave the subject in the
  changeset context under `:ash_agent` (`start` has read it as the person starting the
  run). A request or start they already refused is invalid, and this change leaves it
  alone. A run's scope is read without authorization: the run is the requester's own
  (`AshEnterprise.Execution.Validations.OwnsParent` refuses any other), and which key
  seals a row is the action's bookkeeping, not a read on the requester's behalf.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution.{Invocation, Run}
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
      _no_scope -> rerun_scope(changeset) || run_scope(changeset) || requester_scope(actor)
    end
  end

  # `rerun_of_id` is written only by the rerun change, which has read the original as
  # the person; which key seals the copy is bookkeeping, so it is read without
  # authorization. An original with no active scope has no arguments to copy, and the
  # rerun change refuses it before this runs.
  defp rerun_scope(%{resource: Invocation} = changeset) do
    case Ash.Changeset.get_attribute(changeset, :rerun_of_id) do
      nil ->
        nil

      original_id ->
        Invocation
        |> Ash.Query.filter(id == ^original_id)
        |> Ash.Query.select([:erasure_scope_id])
        |> Ash.read_one(tenant: changeset.tenant, authorize?: false)
        |> case do
          {:ok, %{erasure_scope_id: scope_id}} when is_binary(scope_id) -> {:ok, scope_id}
          {:ok, _no_scope} -> {:error, "the request it reruns has no erasure scope"}
          {:error, error} -> {:error, Exception.message(error)}
        end
    end
  end

  defp rerun_scope(_changeset), do: nil

  defp run_scope(changeset) do
    case Ash.Changeset.get_attribute(changeset, :run_id) do
      nil ->
        nil

      run_id ->
        Run
        |> Ash.Query.filter(id == ^run_id)
        |> Ash.Query.select([:erasure_scope_id])
        |> Ash.read_one(tenant: changeset.tenant, authorize?: false)
        |> case do
          {:ok, %{erasure_scope_id: scope_id}} when is_binary(scope_id) -> {:ok, scope_id}
          {:ok, _no_run} -> nil
          {:error, error} -> {:error, Exception.message(error)}
        end
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

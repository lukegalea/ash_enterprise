defmodule AshEnterprise.Planning.Changes.ScopeAndOwner do
  @moduledoc """
  Names the owner and the erasure scope a planning row's sealed content is sealed under
  (ADR 0024), before `AshEnterprise.Erasure.Changes.SealUnderScope` seals it.

      change {AshEnterprise.Planning.Changes.ScopeAndOwner, from: :requester}
      change {AshEnterprise.Planning.Changes.ScopeAndOwner, from: :run}
      change {AshEnterprise.Planning.Changes.ScopeAndOwner, from: :candidate}

    * `from: :requester` — a run's requester. The person owns the run and its content is
      theirs, so it is sealed under their own scope (the same `data_subject` scope an
      invocation's arguments are sealed under: one scope per person). Only a person's own
      request is sealed; no other actor can open one.
    * `from: :run` — a candidate takes its owner and scope from its run, named by `run_id`.
    * `from: :candidate` — a check result takes them from its candidate, named by
      `candidate_id`.

  The owner and the scope are never accepted as input: they are forced from the parent, so
  the person who requested a run reads its candidates and checks through the same owner
  grants that let them read the run, and shredding that person's scope reaches every copy of
  what the run made. A parent that is not found in the tenant is an error on the field that
  named it; content is never stored unsealed or under a guessed scope.

  The parent is read without authorization: which key seals a row is the action's
  bookkeeping, not a read on anyone's behalf, and the caller of a machinery-only action is
  the job runner.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Planning.{Candidate, Run}
  alias AshEnterprise.Platform.SystemActor

  @label "Planning requests"

  @impl true
  def init(opts) do
    if Keyword.get(opts, :from) in [:requester, :run, :candidate],
      do: {:ok, opts},
      else: {:error, "from must be :requester, :run or :candidate"}
  end

  @impl true
  def change(changeset, opts, context) do
    if changeset.valid? do
      case resolve(opts[:from], changeset, context.actor) do
        {:ok, attrs} ->
          Ash.Changeset.force_change_attributes(changeset, attrs)

        {:error, field, message} ->
          Ash.Changeset.add_error(changeset, field: field, message: message)
      end
    else
      changeset
    end
  end

  defp resolve(:requester, _changeset, %{id: id}) when is_binary(id) do
    case Erasure.ensure_scope(:data_subject, SealingScope.scope_ref(id), %{label: @label},
           actor: SystemActor.system()
         ) do
      {:ok, %{status: :active, id: scope_id}} ->
        {:ok, %{owner_id: id, erasure_scope_id: scope_id}}

      {:ok, _shredded} ->
        {:error, :erasure_scope_id, "the requester's erasure scope is shredded"}

      {:error, error} ->
        {:error, :erasure_scope_id, Exception.message(error)}
    end
  end

  defp resolve(:requester, _changeset, _actor),
    do: {:error, :erasure_scope_id, "only a person's request can be sealed"}

  defp resolve(:run, changeset, _actor),
    do: parent(Run, :run_id, changeset)

  defp resolve(:candidate, changeset, _actor),
    do: parent(Candidate, :candidate_id, changeset)

  defp parent(resource, field, changeset) do
    case Ash.Changeset.get_attribute(changeset, field) do
      id when is_binary(id) ->
        resource
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.select([:id, :owner_id, :erasure_scope_id])
        |> Ash.read_one(tenant: changeset.tenant, authorize?: false)
        |> case do
          {:ok, %{owner_id: owner_id, erasure_scope_id: scope_id}} when is_binary(scope_id) ->
            {:ok, %{owner_id: owner_id, erasure_scope_id: scope_id}}

          {:ok, _not_found} ->
            {:error, field, "no such row in this tenant"}

          {:error, error} ->
            {:error, field, Exception.message(error)}
        end

      _unnamed ->
        {:error, field, "is required"}
    end
  end
end

defmodule AshEnterprise.Planning.Changes.PinModel do
  @moduledoc """
  A run pins a model version and a binding that exist in its own tenant, and resolves the
  binding **as of the run's knowledge cutoff**, never as of now (ADR 0062, #147 draft
  §Binding: "resolve as-of the Run's knowledge_cutoff, then copy the resolved versions into
  the snapshot").

      change {PinModel, stage: :request}, on: [:create]
      change {PinModel, stage: :prepare}, on: [:update], where: action_is(:prepare)

    * `stage: :request` — `model_version_id` and `binding_id` arrive as input from a person's
      self-service request, and a foreign key alone would accept another tenant's id, or a
      draft. Both are read without authorization (the member asking holds no grant on either:
      which model a plan is made with is the binding's decision, not the requester's). The
      model version must be `:published`; the binding must exist. A binding is temporal, but
      its `id` names the record across versions, so the request pins the record and the
      *version* is resolved later, as of the cutoff.
    * `stage: :prepare` — when preparation produced a snapshot (`:prepared` or
      `:needs_input`), the binding must exist as of `knowledge_cutoff`: a backdated or
      replayed run whose cutoff predates the binding is refused, and a binding changed after
      the cutoff resolves to the version that was valid at it. The cutoff may not be in the
      future. The pinned model version may by now be `:retired` (retiring takes it out of
      new use, not out of old runs) but never a draft. A `:preparation_failed` run only
      records the failure.

  The model version is not temporal, so its status is read as it is now; the immutable
  content hashes are what the snapshot pins. The actor is used as loaded, never re-fetched
  as of the cutoff.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Planning.{Binding, ModelVersion}

  @impl true
  def init(opts) do
    if Keyword.get(opts, :stage) in [:request, :prepare],
      do: {:ok, opts},
      else: {:error, "stage must be :request or :prepare"}
  end

  @impl true
  def change(changeset, opts, _context) do
    if changeset.valid? do
      stage(opts[:stage], changeset)
    else
      changeset
    end
  end

  defp stage(:request, changeset) do
    changeset
    |> pin_model_version(changeset, [:published])
    |> pin_binding(nil)
  end

  defp stage(:prepare, changeset) do
    case Ash.Changeset.get_attribute(changeset, :preparation_status) do
      status when status in [:prepared, :needs_input] ->
        pin_at_cutoff(changeset, Ash.Changeset.get_attribute(changeset, :knowledge_cutoff))

      _failed ->
        changeset
    end
  end

  defp pin_at_cutoff(changeset, %DateTime{} = cutoff) do
    if DateTime.compare(cutoff, DateTime.utc_now()) == :gt do
      error(changeset, :knowledge_cutoff, "may not be in the future")
    else
      changeset
      |> pin_model_version(changeset, [:published, :retired])
      |> pin_binding(cutoff)
    end
  end

  defp pin_at_cutoff(changeset, _missing), do: error(changeset, :knowledge_cutoff, "is required")

  defp pin_model_version(changeset, source, allowed) do
    id = Ash.Changeset.get_attribute(source, :model_version_id)

    case is_binary(id) && Ash.get(ModelVersion, id, tenant: changeset.tenant, authorize?: false) do
      false ->
        changeset

      {:ok, %ModelVersion{status: status}} ->
        if status in allowed,
          do: changeset,
          else:
            error(
              changeset,
              :model_version_id,
              "is not a #{Enum.join(allowed, " or ")} model version"
            )

      {:error, _not_found} ->
        error(changeset, :model_version_id, "no such row in this tenant")
    end
  end

  defp pin_binding(changeset, as_of) do
    id = Ash.Changeset.get_attribute(changeset, :binding_id)

    opts =
      [tenant: changeset.tenant, authorize?: false]
      |> then(&if(as_of, do: Keyword.put(&1, :as_of, as_of), else: &1))

    case is_binary(id) && Ash.get(Binding, id, opts) do
      false ->
        changeset

      {:ok, %Binding{}} ->
        changeset

      {:error, _not_found} ->
        message =
          if as_of,
            do: "no such binding in this tenant as of the knowledge cutoff",
            else: "no such row in this tenant"

        error(changeset, :binding_id, message)
    end
  end

  defp error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end

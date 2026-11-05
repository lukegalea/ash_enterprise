defmodule AshEnterprise.Quality.Changes.PinManifest do
  @moduledoc """
  A suite run's `start`, when it names a release manifest (`release_manifest_id`): makes the
  run a measurement of exactly that manifest, which is what the release gate looks for
  (`AshEnterprise.Execution.Release.Gate`).

  It runs after `AshEnterprise.Quality.Changes.StartCases` has pinned the candidate, and
  requires that:

    * the manifest is resolved or requested, and the run is `:offline`: a release is
      measured on the cases alone, not beside live work;
    * the suite is one the manifest pins, at the content it pinned (`suite_content_hash`);
    * the agent is one the manifest pins, and the version the cases will run
      (`agent_version_id`, the latest published) is the one it pinned: a version published
      since means the manifest must be resolved again.

  The run then records the manifest's `manifest_digest` as its `candidate_digest`.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution

  @impl true
  def change(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :release_manifest_id) do
      nil -> changeset
      id -> Ash.Changeset.before_action(changeset, &pin(&1, id, context))
    end
  end

  defp pin(changeset, id, context) do
    with {:ok, manifest} <-
           Execution.get_release_manifest(
             id,
             Ash.Context.to_opts(context, tenant: changeset.tenant)
           ),
         :ok <- measurable(manifest, changeset) do
      Ash.Changeset.force_change_attribute(changeset, :candidate_digest, manifest.manifest_digest)
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, field: :release_manifest_id, message: message)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp measurable(%{status: status}, _changeset) when status not in [:resolved, :requested],
    do: {:error, "is #{status}; only a resolved or requested manifest is measured"}

  defp measurable(manifest, changeset) do
    attr = &Ash.Changeset.get_attribute(changeset, &1)

    cond do
      attr.(:mode) != :offline ->
        {:error, "is measured by an offline suite run only"}

      not pinned?(manifest, "suite", :id, attr.(:suite_id)) ->
        {:error, "does not pin this suite"}

      not pinned?(manifest, "suite", :digest, attr.(:suite_content_hash)) ->
        {:error, "pins another version of this suite: resolve it again"}

      not pinned?(manifest, "agent", :id, attr.(:agent_version_id)) ->
        {:error, "does not pin the agent's latest published version: resolve it again"}

      true ->
        :ok
    end
  end

  defp pinned?(manifest, kind, field, value) do
    Enum.any?(manifest.entries, fn
      %{"annotations" => %{"kind" => ^kind}} = entry ->
        case field do
          :id -> entry["annotations"]["id"] == value
          :digest -> entry["digest"]["sha256"] == value
        end

      _other ->
        false
    end)
  end
end

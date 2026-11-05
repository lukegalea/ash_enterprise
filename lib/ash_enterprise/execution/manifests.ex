defmodule AshEnterprise.Execution.Manifests do
  @moduledoc """
  Which release is active for a thing, in a tenant (`AshAgent.ReleaseManifest`).

  A tenant may run several releases at once, one active manifest per key
  (`AshEnterprise.Execution.ReleaseManifest`), each covering what its entries name. The
  release that covers a tool is the active one with a `tool` entry for it; the one that
  covers a process is the active one with a `process` entry for its key.

  The release that covers an agent decides which of its versions live runs start on
  (`agent_version/2`): the one its `agent` entry pins, whatever has been published since. A
  candidate is therefore not live until a release that pins it is promoted, and a rollback
  returns to the version the earlier release pinned. An agent no active release names runs
  its latest published version, as an agent that has never been released does.

  Read without authorization, as the machinery reads: a request asks which release it falls
  under, and the person making it is not entitled to read manifests for that. The few active
  manifests of a tenant are read in one query and matched here.
  """

  @behaviour AshAgent.ReleaseManifest

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Release.Entries

  @impl true
  def active(target, tenant), do: covering(:tool, target, tenant)

  @impl true
  def agent_version(key, tenant) do
    case covering_manifest(:agent, key, tenant) do
      nil -> {:ok, nil}
      manifest -> {:ok, Entries.find(manifest.entries, :agent, key)["annotations"]["id"]}
    end
  end

  @doc """
  The active release in `tenant` with an entry of `kind` named `name`, as
  `{:ok, %{id: id, digest: manifest_digest}}`, or `{:ok, nil}`.
  """
  @spec covering(atom(), String.t(), Ash.UUID.t() | nil) ::
          {:ok, %{id: Ash.UUID.t(), digest: String.t()} | nil}
  def covering(_kind, _name, nil), do: {:ok, nil}

  def covering(kind, name, tenant) do
    manifest = covering_manifest(kind, name, tenant)
    {:ok, manifest && %{id: manifest.id, digest: manifest.manifest_digest}}
  end

  defp covering_manifest(kind, name, tenant) do
    [authorize?: false, tenant: tenant]
    |> Execution.active_release_manifests!()
    |> Enum.find(&Entries.find(&1.entries, kind, name))
  end
end

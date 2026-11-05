defmodule Battery.Execution.ReleaseManifest do
  @moduledoc """
  The battery's stand-in for a host's release store (`AshAgent.ReleaseManifest`): the
  active release is whatever `activate/1` last set, and covers every target. A host reads
  its own manifests here; the seam under test is what the invocation does with the answer.
  """

  @behaviour AshAgent.ReleaseManifest

  @key {__MODULE__, :active}

  @impl true
  def active(_target, _tenant), do: {:ok, :persistent_term.get(@key, nil)}

  @doc "Makes a release with `digest` the active one."
  @spec activate(String.t()) :: %{id: Ash.UUID.t(), digest: String.t()}
  def activate(digest) do
    active = %{id: Ash.UUID.generate(), digest: digest}
    :persistent_term.put(@key, active)
    active
  end

  @doc "No release is active."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end
end

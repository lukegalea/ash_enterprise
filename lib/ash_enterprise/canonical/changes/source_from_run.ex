defmodule AshEnterprise.Canonical.Changes.SourceFromRun do
  @moduledoc """
  An action item captured by a run of an agent is `source: :assistant`: the assistant
  asked for it, and the person confirmed it (ADR 0055). It runs as their governed
  invocation, keyed `run:<run id>:<step seq>:<tool call id>`, so the key the executor
  passes in the changeset's `:ash_agent` context says so; the model never chooses the
  source.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.context do
      %{ash_agent: %{invocation_key: "run:" <> _rest}} ->
        Ash.Changeset.force_change_attribute(changeset, :source, "assistant")

      _other ->
        changeset
    end
  end
end

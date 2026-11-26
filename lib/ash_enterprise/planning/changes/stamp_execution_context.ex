defmodule AshEnterprise.Planning.Changes.StampExecutionContext do
  @moduledoc """
  Records the execution context a candidate's write ran in on its audit event, as
  `metadata.execution_context` (ADR 0080), beside what
  `AshEnterprise.Platform.Changes.StampCorrelation` put there.

  The context comes from the candidate's `world`, which `propose` copies from its run and no
  action accepts as input: `:operational` is `:live` and `:scenario` is `:scenario`. It is
  read in a `before_action`, after the copy has run, so the event of `propose` carries the
  run's context too.
  """

  use Ash.Resource.Change

  @contexts %{operational: "live", scenario: "scenario"}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Map.fetch(@contexts, Ash.Changeset.get_attribute(changeset, :world)) do
        {:ok, context} ->
          metadata =
            changeset.context
            |> Map.get(:ash_events_metadata, %{})
            |> Map.put("execution_context", context)

          Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})

        :error ->
          changeset
      end
    end)
  end

  @impl true
  def temporal_safe?(_opts), do: true
end

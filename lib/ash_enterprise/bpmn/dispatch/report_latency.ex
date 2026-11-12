defmodule AshEnterprise.Bpmn.Dispatch.ReportLatency do
  @moduledoc """
  Reports how long an event waited to start its process, as the dispatch that started it is
  written (`AshEnterprise.Bpmn.Telemetry.dispatch_started/3`). Nothing for a dispatch that
  started nothing.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, dispatch ->
      if dispatch.status == :started do
        AshEnterprise.Bpmn.Telemetry.dispatch_started(
          dispatch.organization_id,
          dispatch.kind,
          dispatch.event_occurred_at
        )
      end

      {:ok, dispatch}
    end)
  end
end

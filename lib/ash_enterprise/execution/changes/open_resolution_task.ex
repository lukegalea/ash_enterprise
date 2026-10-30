defmodule AshEnterprise.Execution.Changes.OpenResolutionTask do
  @moduledoc """
  On `request_resolution`: opens the standalone task a person settles the invocation's
  unknown outcome with (`AshEnterprise.Execution.Resolution`), in the same transaction.

  It delegates to `AshBpmn.Changes.RequireApproval`, the engine's standalone-task change
  (spike S6), with the static key `"invocation.resolution"`: one live task per row and
  key, which the engine's partial unique index enforces. The candidates are the
  tenant's administrators. Nobody is excluded: settling what happened is a matter of
  fact, not a second pair of eyes on a request, and the requester may be the one who
  can check it. No `on_complete`: the `:apply_resolution` trigger applies the decision.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Resolution

  @impl true
  def change(changeset, _opts, context) do
    Ash.Resource.Change.change(
      AshBpmn.Changes.RequireApproval,
      changeset,
      [
        key: Resolution.key(),
        name: "Settle an invocation whose outcome is unknown",
        outcomes: [:succeeded, :failed, :retry],
        candidates: [%{"kind" => "role", "of" => "Administrator"}]
      ],
      context
    )
  end
end

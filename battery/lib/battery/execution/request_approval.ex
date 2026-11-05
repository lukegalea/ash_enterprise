defmodule Battery.Execution.RequestApproval do
  @moduledoc """
  On `request`: a row awaiting approval gets a standalone ash_bpmn approval task, with
  options computed from the target's effects declaration and delegated to
  `AshBpmn.Changes.RequireApproval`: the static key `"invocation.approval"`, the holders
  of the declaration's `approver_role` as candidates, the requester excluded under
  four eyes, and the declaration's expiry. No `on_complete`.
  """

  use Ash.Resource.Change

  @key "invocation.approval"

  @doc "The approval task's key."
  def key, do: @key

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_attribute(changeset, :status) == :awaiting_approval do
      effects = Ash.Changeset.get_attribute(changeset, :effects)

      opts = [
        key: @key,
        name: "Approve #{Ash.Changeset.get_attribute(changeset, :target)}",
        outcomes: [:approved, :rejected],
        candidates: candidates(effects),
        excluding: if(effects["approval"] == "four_eyes", do: ["subject.owner_id"], else: []),
        expire_in: Enum.map(effects["approval_expires_in"] || %{}, &unit/1)
      ]

      Ash.Resource.Change.change(AshBpmn.Changes.RequireApproval, changeset, opts, context)
    else
      changeset
    end
  end

  # The holders of the declared role; a `:confirm` target that names none is confirmed
  # by the person who asked.
  defp candidates(%{"approver_role" => role}) when is_binary(role),
    do: [%{"kind" => "role", "of" => role}]

  defp candidates(_effects), do: [%{"kind" => "user", "of" => "subject.owner_id"}]

  defp unit({"days", n}), do: {:days, n}
  defp unit({"hours", n}), do: {:hours, n}
  defp unit({"minutes", n}), do: {:minutes, n}
end

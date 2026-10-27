defmodule AshEnterprise.AgentSpike.RequestApproval do
  @moduledoc """
  The shape the plan gives the host's approval wrapper (S6): the approval's
  options are computed when the action runs, from a declaration the caller
  supplies, and the change delegates to `AshBpmn.Changes.RequireApproval`
  the way `optimistic_lock` delegates to `increment`.

  The declaration arrives in the changeset context as
  `:approval_declaration`, standing in for a target's effects declaration:

      %{approver_role: "Clinic lead", approval: :four_eyes, expires_in: [days: 3]}

  It yields: candidates holding the approver role, `excluding` the subject's
  owner under four-eyes, `expire_in` from the declaration, and the static key
  `"invocation.approval"`.
  """

  use Ash.Resource.Change

  @key "invocation.approval"

  @doc "The static approval key, one per subject."
  def key, do: @key

  @impl true
  def change(changeset, _opts, context) do
    declaration = Map.fetch!(changeset.context, :approval_declaration)

    excluding =
      if declaration.approval == :four_eyes, do: ["subject.owner_id"], else: []

    opts = [
      key: @key,
      name: "Approve the requested step",
      outcomes: [:approved, :rejected],
      candidates: [%{"kind" => "role", "of" => declaration.approver_role}],
      excluding: excluding,
      expire_in: declaration.expires_in
    ]

    Ash.Resource.Change.change(AshBpmn.Changes.RequireApproval, changeset, opts, context)
  end
end

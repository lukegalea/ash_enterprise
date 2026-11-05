defmodule AshEnterprise.SystemOne.Changes.RecordApprover do
  @moduledoc """
  Sets `certified_by` to the person who approved the governed invocation the update runs
  as (ADR 0061). On a revocation it is the record of who revoked: the update still runs as
  the person who requested it, and names the person who approved it. Where requester and
  approver are the same (the click), it is that person.

  See `AshEnterprise.Execution.Approver`.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Approver

  @impl true
  def change(changeset, _opts, context) do
    email = Approver.email(changeset.context[:ash_agent], context.actor, changeset.tenant)

    Ash.Changeset.force_change_attribute(changeset, :certified_by, email)
  end
end

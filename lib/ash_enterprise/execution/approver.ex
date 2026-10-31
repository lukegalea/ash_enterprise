defmodule AshEnterprise.Execution.Approver do
  @moduledoc """
  Who approved the invocation a governed target is running as (ADR 0061, follow-up of
  2026-10-31).

  An approved request still executes as the person who made it: no grants are borrowed.
  The record the target writes (a certification, a revocation) names the person who
  approved the request instead, read from the invocation's `approved_by_id`, which
  `apply_decision` set from the decided approval task. When the requester approves their
  own request (the click on a judgment surface) the two are the same person.

  The executor hands a target its invocation under `context.ash_agent`
  (`AshAgent.Invocation.Executor.context/1`). `Governed` has already checked that context
  before the target runs, so this reads it without authorization, in the action's tenant.
  """

  alias AshEnterprise.Accounts
  alias AshEnterprise.Execution.Invocation

  @doc """
  The email of the person who approved the invocation named by `ash_context` (the
  action's `context`), or the executing `actor`'s when there is no approver on record.
  """
  @spec email(map() | nil, term(), Ash.UUID.t() | nil) :: String.t()
  def email(ash_context, actor, tenant) do
    with %{invocation_id: id} <- ash_context,
         {:ok, %{approved_by_id: approver_id}} when is_binary(approver_id) <-
           Ash.get(Invocation, id, tenant: tenant, authorize?: false, not_found_error?: false),
         {:ok, %{email: email}} <- Accounts.get_user(approver_id, authorize?: false) do
      to_string(email)
    else
      _no_distinct_approver -> to_string(actor.email)
    end
  end
end

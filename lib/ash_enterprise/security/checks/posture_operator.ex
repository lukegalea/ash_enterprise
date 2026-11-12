defmodule AshEnterprise.Security.Checks.PostureOperator do
  @moduledoc """
  The grant path that lets the platform operator set an approval posture
  (`AshEnterprise.Accounts.Organization`'s `set_approval_posture`): the one act
  a tenant's own grants cannot give an outsider, because the posture decides
  who approves in that tenant and a tenant being set up, or one whose only
  administrator is locked out of four eyes, may need someone the platform —
  not the tenant — vouches for.

  The operator is who `AshEnterprise.Execution.Authority` names as one
  (`c:AshAgent.Approval.Authority.operator?/1`): a
  person holding `write` at `:global` on one of the operator-only resources
  (`AshEnterprise.Security.Privilege.operator_only?/1`), the grant
  `mix ash_enterprise.platform.grant_operator` makes. The action's own
  validation (`AshAgent.Approval.Validations.PostureChange`) still decides
  whether the change itself is allowed: this check only says who may reach the
  action at all.

  Contributed nothing to any other action: the check reads the action it is
  asked about and answers for `set_approval_posture` alone, the way
  `AshEnterprise.Security.Checks.SelfService` answers for the actions its
  resource declares. It is one more `authorize_if` in the grant union on
  `Organization` (`extra_grants:`) — a way in, never a way out — and one of
  the disjuncts of the action's own policy beside
  `AshEnterprise.Security.Checks.OwnOrganization`.

  A simple check rather than a filter check: the answer does not depend on the
  record, so there is no filter to build. Like every check it never queries —
  the operator's grants are already on the actor's precomputed
  `AshEnterprise.Security.ActorContext`.
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Execution.Authority

  @action :set_approval_posture

  @impl true
  def describe(_opts),
    do: "action sets an approval posture and the actor is the platform operator"

  @impl true
  def match?(actor, %{action: %{name: @action}} = _context, _opts),
    do: Authority.operator?(actor)

  def match?(_actor, _context, _opts), do: false
end

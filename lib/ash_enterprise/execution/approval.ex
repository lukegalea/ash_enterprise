defmodule AshEnterprise.Execution.Approval do
  @moduledoc """
  Who approves an invocation, and whether they still may (ADR 0055, "Approval binding").

  What an approval binds is the fragment's: `request` records the request's
  `authorization_details` (RFC 9396), their `approval_digest` and `approval_expires_at`,
  and `apply_decision` and every `claim` find the row `stale` when the digest recomputed
  from the row, the target as declared now and the subject as it stands now no longer
  matches, or the approval has expired (`AshAgent.Invocation.Approval`). This module
  answers the rest, from the target's effects declaration as it was snapshotted on the
  row:

    * **The task.** One standalone `HumanTask` per invocation, under the static key
      `"invocation.approval"` (one invocation has one approval, and the engine allows one
      live task per subject and key), opened by `request` through
      `AshEnterprise.Execution.Changes.RequestApproval`, decided through the existing
      `HumanTask.approve` and `reject` doors, and applied by the `:apply_decision`
      trigger (`AshEnterprise.Execution.Changes.ReadApproval`). Never `on_complete`.
    * **The candidates.** The holders of the declaration's `approver_role`, the role
      named by it in words (`:credentialing_committee` is the role "Credentialing
      committee", `:administrator` is "Administrator"). A `:confirm` target that names
      no role is confirmed by the person who asked. Candidates are people: an automation
      principal holds no person's role, so it never approves.
    * **Four eyes.** `:four_eyes` excludes the requester (`subject.owner_id`), even when
      they hold the approver role.
    * **The sole administrator** (amended 2026-11-01). An organization with one
      administrator could never approve a four-eyes request that names the
      Administrator role, such as publishing an agent: the requester is excluded and
      there is no one else. An organization may opt in
      (`Organization.sole_administrator_approval`, set by its administrator through
      `set_sole_administrator_approval`). Then, for a `:four_eyes` declaration whose
      `approver_role` is `:administrator`, and only that role, the requester is not
      excluded while they are the only person who holds the Administrator role in the
      tenant or has ever held it, directly or through a team (`sole_administrator?/3`).
      An administrator who was revoked, taken off a team or deactivated still counts:
      each of those is one person's act, so the first administrator cannot remove the
      second and then approve alone. They still approve
      by deciding the task; nothing is approved for them. The rule is asked when the
      task opens, when the decision is applied and at every claim: a second
      administrator, or the opt-in turned off, restores four eyes, and a self-approval
      made before then goes `stale`. An approval made under the rule is recorded on the
      invocation as `approval_basis` `:sole_administrator` (`basis/2`), so it is never
      mistaken for four eyes. Other roles, such as the credentialing committee, are
      never affected.
    * **Authority now.** `approver_holds?/2`: the approver is still an active member of
      the invocation's tenant and, from a freshly built `ActorContext`, still a
      candidate (directly or through a team), and not excluded. Asked when the decision
      is applied and again at every claim; claim logic, not a policy check, so it reads.
  """

  alias AshEnterprise.Accounts.{Organization, TeamMembership}
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Process.AssignmentResolver
  alias AshEnterprise.Security.{ActorContext, Role, TeamRole, UserRole}

  @key "invocation.approval"

  @doc "The standalone task key an approval is opened under."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The options `AshBpmn.Changes.RequireApproval` opens the approval task with, for a
  request of `target` whose effects declaration was snapshotted as `effects`, made by
  `requester_id` in `tenant` (for the sole-administrator rule, `sole_administrator?/3`).
  """
  @spec task_options(String.t(), map(), Ash.UUID.t() | nil, Ash.UUID.t() | nil) :: keyword()
  def task_options(target, effects, tenant, requester_id) do
    [
      key: @key,
      name: "Approve #{target |> String.split(".") |> Enum.take(-2) |> Enum.join(".")}",
      outcomes: [:approved, :rejected],
      candidates: candidates(effects),
      excluding: excluding(effects, sole_administrator?(tenant, requester_id, effects)),
      expire_in: expire_in(effects)
    ]
  end

  @doc """
  Whether the sole-administrator rule lets `requester_id` approve their own request in
  `tenant`, for a request whose effects declaration was snapshotted as `effects`: the
  declaration is `:four_eyes` with `approver_role` `:administrator`, the organization
  has opted in (`sole_administrator_approval`), and the requester is the only person
  who holds the Administrator role in the tenant or has ever held it, directly or
  through a team (revoked assignments, ended memberships and deactivated people count).

  Reads the organization and the role's holders as they are now; claim logic, never a
  policy check.
  """
  @spec sole_administrator?(Ash.UUID.t() | nil, Ash.UUID.t() | nil, map() | nil) :: boolean()
  def sole_administrator?(tenant, requester_id, %{
        "approval" => "four_eyes",
        "approver_role" => "administrator"
      })
      when is_binary(tenant) and is_binary(requester_id) do
    opted_in?(tenant) and holders(tenant, role_name(:administrator)) == [requester_id]
  end

  def sole_administrator?(_tenant, _requester_id, _effects), do: false

  @doc """
  What an approval of `invocation` by `approver_id` rests on, once
  `approver_holds?/2` has accepted it: `:sole_administrator` when the requester
  approved their own four-eyes request under the sole-administrator rule, otherwise
  the row's `approval_mode` (`:four_eyes` or `:confirm`).
  """
  @spec basis(Ash.Resource.record(), Ash.UUID.t()) :: :confirm | :four_eyes | :sole_administrator
  def basis(%{approval_mode: :four_eyes, owner_id: owner_id}, owner_id)
      when is_binary(owner_id),
      do: :sole_administrator

  def basis(%{approval_mode: mode}, _approver_id), do: mode

  @doc "The role `approver_role` names: `:credentialing_committee` is \"Credentialing committee\"."
  @spec role_name(atom() | String.t()) :: String.t()
  def role_name(approver_role),
    do: approver_role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @doc """
  Whether `approver_id` may still approve `invocation`: an active member of its tenant,
  still a candidate for its approval (their user or one of their teams), and not
  excluded from it.
  """
  @spec approver_holds?(Ash.Resource.record(), Ash.UUID.t() | nil) :: boolean()
  def approver_holds?(_invocation, nil), do: false

  def approver_holds?(invocation, approver_id) do
    tenant = invocation.organization_id
    ctx = %{subject: invocation, actor: nil, tenant: tenant}

    with {:ok, approver} <-
           Identity.actor_for(%{
             executing_principal: %{type: :person, id: approver_id},
             organization_id: tenant
           }),
         {:ok, candidates} <- AssignmentResolver.candidates(candidates(invocation.effects), ctx),
         {:ok, excluded} <-
           AssignmentResolver.exclusions(excluding(invocation.effects, sole?(invocation)), ctx) do
      principal_ids = ActorContext.for_actor(approver).principal_ids

      approver_id not in excluded and Enum.any?(candidates, &(&1.id in principal_ids))
    else
      _no_authority -> false
    end
  end

  defp candidates(%{"approver_role" => role}) when is_binary(role),
    do: [%{"kind" => "role", "of" => role_name(role)}]

  defp candidates(_effects), do: [%{"kind" => "user", "of" => "subject.owner_id"}]

  # Under the sole-administrator rule the requester is not excluded; otherwise four eyes
  # excludes them.
  defp excluding(_effects, true = _sole_administrator?), do: []
  defp excluding(%{"approval" => "four_eyes"}, _sole_administrator?), do: ["subject.owner_id"]
  defp excluding(_effects, _sole_administrator?), do: []

  defp sole?(invocation),
    do: sole_administrator?(invocation.organization_id, invocation.owner_id, invocation.effects)

  # Read without authorization, in the tenant: deciding who may approve is claim logic,
  # and the requester is not entitled to read who else holds a role.
  defp opted_in?(tenant) do
    case Ash.get(Organization, tenant, authorize?: false, not_found_error?: false) do
      {:ok, %Organization{sole_administrator_approval: true}} -> true
      _other -> false
    end
  end

  # Everyone who holds `role` in `tenant` or has ever held it, directly or through a
  # team: assignments in force or revoked, memberships current or ended, people active
  # or not, wherever they are now. Revoking a role, taking someone off a team and
  # deactivating them are each one person's act, so a holder removed that way still
  # counts, and four eyes stays closed as it would without the rule. The `history`
  # reads include archived rows.
  defp holders(tenant, role) do
    opts = [authorize?: false, tenant: tenant]
    role_ids = ids(Role, [name: role], :id, opts)
    team_ids = ids(TeamRole, [role_id: [in: role_ids]], :team_id, opts)

    Enum.uniq(
      ids(UserRole, [role_id: [in: role_ids]], :user_id, opts) ++
        ids(TeamMembership, [team_id: [in: team_ids]], :user_id, opts)
    )
  end

  defp ids(resource, filter, field, opts) do
    resource
    |> Ash.Query.for_read(:history, %{}, opts)
    |> Ash.Query.filter_input(filter)
    |> Ash.Query.select([field])
    |> Ash.read!()
    |> Enum.map(&Map.fetch!(&1, field))
  end

  @units %{"days" => :days, "hours" => :hours, "minutes" => :minutes}

  defp expire_in(%{"approval_expires_in" => duration}) when is_map(duration),
    do: Enum.map(duration, fn {unit, n} -> {Map.fetch!(@units, unit), n} end)

  defp expire_in(_effects), do: nil
end

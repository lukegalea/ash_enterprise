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
      An approver may instead ask the requester for more information
      (`HumanTask.request_info`, `AshEnterprise.Execution.InfoRequest`); the row's
      next approval task opens when they have answered.
    * **The rule.** Who may decide is the package's
      (`AshAgent.Approval.Posture`, through `AshAgent.Invocation.Approval.rule/2`):
      under `:standard` four eyes — another holder of the declaration's
      `approver_role`, the requester excluded; under `:small_team` the requester
      may decide their own request when they hold that role, and any
      administrator (the requester included) when nobody holds it; under
      `:implementation` the requester confirms, until the posture's end date
      passes. An effect declared `posture_floor?: true` keeps `:standard`
      behaviour under every posture, and agents and automation principals are
      never candidates. The posture in force, the role's holders and the
      administrators are facts this host answers through
      `AshEnterprise.Execution.Authority`. A `:confirm` target is the same under
      every posture: a holder of its `approver_role` confirms it when it names one,
      otherwise the person who asked. Candidates are people: an
      automation principal holds no person's role, so it never approves.
    * **Authority now.** `approver_holds?/2`: the approver is still an active member of
      the invocation's tenant and, from a freshly built `ActorContext`, still a
      candidate under the rule in force now (directly or through a team), and not
      excluded from it. Asked when the decision is applied and again at every claim;
      claim logic, not a policy check, so it reads.
  """

  alias AshEnterprise.Execution.{Identity, Invocation}
  alias AshEnterprise.Process.AssignmentResolver
  alias AshEnterprise.Security.ActorContext

  @key "invocation.approval"

  @doc "The standalone task key an approval is opened under."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The approval rule for `invocation` under the posture in force in its tenant:
  `AshAgent.Invocation.Approval.rule/2`, which asks
  `AshEnterprise.Execution.Authority` for the posture and the facts.
  """
  @spec rule(Ash.Resource.record()) :: AshAgent.Approval.Posture.rule()
  def rule(invocation),
    do: AshAgent.Invocation.Approval.rule(invocation, tenant: invocation.organization_id)

  @doc """
  The options `AshBpmn.Changes.RequireApproval` opens the approval task with,
  for a request as it will be written (`row`: its target, the effects
  declaration as the fragment snapshotted it, the mode, the executing
  principal, the owner and the tenant), under the posture in force
  (`rule/1`).
  """
  @spec task_options(Invocation.t()) :: keyword()
  def task_options(row) do
    rule = rule(row)

    [
      key: @key,
      name: "Approve #{short_name(row.target)}",
      outcomes: [:approved, :rejected, :request_info],
      candidates: candidates(row, rule),
      excluding: excluding(rule),
      expire_in: expire_in(row.effects)
    ]
  end

  @doc """
  Whether `approver_id` may still approve `invocation`: an active member of its tenant,
  still a candidate for its approval under the rule in force (`rule/1`) — their user or
  one of their teams — and not excluded from it.
  """
  @spec approver_holds?(Ash.Resource.record(), Ash.UUID.t() | nil) :: boolean()
  def approver_holds?(_invocation, nil), do: false

  def approver_holds?(invocation, approver_id) do
    tenant = invocation.organization_id
    ctx = %{subject: invocation, actor: nil, tenant: tenant}
    rule = rule(invocation)

    with {:ok, approver} <-
           Identity.actor_for(%{
             executing_principal: %{type: :person, id: approver_id},
             organization_id: tenant
           }),
         {:ok, candidates} <- AssignmentResolver.candidates(candidates(invocation, rule), ctx),
         {:ok, excluded} <- AssignmentResolver.exclusions(excluding(rule), ctx) do
      principal_ids = ActorContext.for_actor(approver).principal_ids

      approver_id not in excluded and Enum.any?(candidates, &(&1.id in principal_ids))
    else
      _no_authority -> false
    end
  end

  @doc """
  The role `approver_role` names: `:credentialing_committee` is "Credentialing
  committee", `:administrator` is "Administrator".
  """
  @spec role_name(atom() | String.t()) :: String.t()
  def role_name(approver_role),
    do: approver_role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # The pool the rule names, as candidate specs for the resolver. A `:confirm`
  # target leaves the pool to the host (the rule's candidates are nil): the holders
  # of its `approver_role` when it names one, otherwise the person who asked, as
  # before the postures.
  defp candidates(row, %{basis: :confirm}), do: approver_role_candidates(row)
  defp candidates(row, %{candidates: :approver_role}), do: approver_role_candidates(row)

  defp candidates(_row, %{candidates: :administrators}),
    do: role_candidates(AshEnterprise.Execution.Authority.administrator_role())

  defp candidates(_row, %{candidates: :requester}),
    do: [%{"kind" => "user", "of" => "subject.owner_id"}]

  defp candidates(_row, %{candidates: nil}), do: []

  # The rule excludes the requester, so four eyes: the BPMN engine's maker-checker
  # exclusion, resolved against the subject's `owner_id`.
  defp excluding(%{exclude_requester?: true}), do: ["subject.owner_id"]
  defp excluding(_rule), do: []

  defp approver_role_candidates(row) do
    case row.effects do
      %{"approver_role" => role} when is_binary(role) -> role_candidates(role)
      %{approver_role: role} when is_atom(role) and not is_nil(role) -> role_candidates(role)
      _no_role -> [%{"kind" => "user", "of" => "subject.owner_id"}]
    end
  end

  defp role_candidates(role), do: [%{"kind" => "role", "of" => role_name(role)}]

  defp short_name(target), do: target |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  @units %{"days" => :days, "hours" => :hours, "minutes" => :minutes}

  defp expire_in(%{"approval_expires_in" => duration}) when is_map(duration),
    do: Enum.map(duration, fn {unit, n} -> {Map.fetch!(@units, unit), n} end)

  defp expire_in(_effects), do: nil
end

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
    * **Authority now.** `approver_holds?/2`: the approver is still an active member of
      the invocation's tenant and, from a freshly built `ActorContext`, still a
      candidate (directly or through a team), and not excluded. Asked when the decision
      is applied and again at every claim; claim logic, not a policy check, so it reads.
  """

  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Process.AssignmentResolver
  alias AshEnterprise.Security.ActorContext

  @key "invocation.approval"

  @doc "The standalone task key an approval is opened under."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The options `AshBpmn.Changes.RequireApproval` opens the approval task with, for a
  request of `target` whose effects declaration was snapshotted as `effects`.
  """
  @spec task_options(String.t(), map()) :: keyword()
  def task_options(target, effects) do
    [
      key: @key,
      name: "Approve #{target |> String.split(".") |> Enum.take(-2) |> Enum.join(".")}",
      outcomes: [:approved, :rejected],
      candidates: candidates(effects),
      excluding: excluding(effects),
      expire_in: expire_in(effects)
    ]
  end

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
         {:ok, excluded} <- AssignmentResolver.exclusions(excluding(invocation.effects), ctx) do
      principal_ids = ActorContext.for_actor(approver).principal_ids

      approver_id not in excluded and Enum.any?(candidates, &(&1.id in principal_ids))
    else
      _no_authority -> false
    end
  end

  defp candidates(%{"approver_role" => role}) when is_binary(role),
    do: [%{"kind" => "role", "of" => role_name(role)}]

  defp candidates(_effects), do: [%{"kind" => "user", "of" => "subject.owner_id"}]

  defp excluding(%{"approval" => "four_eyes"}), do: ["subject.owner_id"]
  defp excluding(_effects), do: []

  @units %{"days" => :days, "hours" => :hours, "minutes" => :minutes}

  defp expire_in(%{"approval_expires_in" => duration}) when is_map(duration),
    do: Enum.map(duration, fn {unit, n} -> {Map.fetch!(@units, unit), n} end)

  defp expire_in(_effects), do: nil
end

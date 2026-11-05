defmodule AshEnterprise.Test.Execution.Releases do
  @moduledoc """
  Helpers the release tests share (ADR 0058): a release taken the whole way, as the people
  involved take it. The author drafts, resolves and asks; a second administrator decides
  the approval; the job runner applies the decision and runs the promotion.
  """

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Test.Execution.Runs

  @doc "A manifest of `key` for `requests` (`[%{kind: , key: }]`), drafted and resolved by the clinic's administrator."
  def resolved!(clinic, key, requests) do
    opts = [actor: clinic.admin.actor, tenant: clinic.tenant]

    key
    |> then(&Execution.create_release_draft!(%{key: &1, requests: requests}, opts))
    |> Execution.resolve_release_manifest!(%{}, opts)
  end

  @doc "Asks for `manifest` to be released, as its author: the gate, then the approval."
  def request(clinic, manifest),
    do: Execution.request_release(manifest.id, actor: clinic.admin.actor, tenant: clinic.tenant)

  @doc """
  The invocation `request_release` opened, approved by the clinic's second administrator
  and applied: the invocation row after `apply_decision`.
  """
  def approve!(clinic, %{"invocation_id" => id}) do
    tenant = clinic.tenant
    row = Execution.get_invocation!(id, authorize?: false, tenant: tenant)
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: clinic.approver.actor,
      tenant: tenant
    )
    |> Ash.run_action!()

    Execution.apply_invocation_decision!(row, Runs.oban(tenant))
  end

  @doc "The manifest taken the whole way to active, or raises where it stops."
  def release!(clinic, key, requests) do
    manifest = resolved!(clinic, key, requests)
    {:ok, asked} = request(clinic, manifest)
    %{status: :ready} = row = approve!(clinic, asked)
    {:ok, :succeeded} = Executor.execute(Invocation, row.id, Runs.oban(clinic.tenant))
    reload(clinic, manifest)
  end

  @doc "`manifest` as committed now."
  def reload(clinic, manifest),
    do: Execution.get_release_manifest!(manifest.id, authorize?: false, tenant: clinic.tenant)
end

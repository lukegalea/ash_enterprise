defmodule AshEnterprise.Execution.Actions.ConfirmRequest do
  @moduledoc """
  `Invocation.confirm`: a person confirms a request of their own, named by its target,
  arguments and key, and it runs now (ADR 0055).

  It is `AshEnterprise.Execution.Actions.ConfirmInvocation` for a caller that holds a
  request rather than a record: `invoke` with the key (the same row again for the same
  request, `AshAgent.Invocation.IdempotencyConflict` for a different one), then
  `ConfirmInvocation.confirm/3`. Under `:confirm` the requester is the approver, so the
  call is the confirmation; under four eyes they are not a candidate, and the request
  keeps waiting for someone who is.

  An ACP prompt that asks permission runs this once the person allows it
  (`AshEnterprise.Acp.Approvals`). It answers for a person to read: the target's own
  answer when it ran and answered in words, otherwise a sentence saying it is done,
  waiting for an approver (with the approval's address), or under way. A request
  that ended `failed`, `rejected` or `stale` is an error, so the caller reports it as
  one.
  """

  use Ash.Resource.Actions.Implementation
  use AshEnterpriseWeb, :verified_routes

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Actions.ConfirmInvocation
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def run(input, _opts, context) do
    %{target: target, args: args, key: key} = input.arguments
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, row} <- Execution.invoke(target, args, %{key: key}, ash_opts),
         {:ok, row} <- ConfirmInvocation.confirm(row, context.actor, ash_opts[:tenant]) do
      sentence(row)
    end
  end

  # The target's own answer when it gave one in words, else what ran.
  defp sentence(%{status: :succeeded} = row) do
    case Ash.load(row, [:result], actor: SystemActor.oban(), tenant: row.organization_id) do
      {:ok, %{result: %{"value" => text}}} when is_binary(text) -> {:ok, text}
      _no_words -> {:ok, "Done: #{label(row.target)}."}
    end
  end

  defp sentence(%{status: :awaiting_approval} = row) do
    {:ok, "Waiting for someone who may approve #{label(row.target)}#{at(row)}."}
  end

  defp sentence(%{status: status} = row)
       when status in [:failed, :rejected, :stale, :cancelled] do
    {:error,
     "#{label(row.target)} #{status}#{if row.error_code, do: ": " <> row.error_code, else: ""}. " <>
       "Nothing was changed."}
  end

  defp sentence(row), do: {:ok, "#{label(row.target)} is under way (#{row.status})."}

  # `AshEnterprise.Bpmn.HumanTask.approve` reads "HumanTask.approve".
  defp label(target), do: target |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  defp at(row) do
    case Ash.load(row, :approval_task, authorize?: false) do
      {:ok, %{approval_task: %{id: id}}} -> ": " <> url(~p"/app/r/approvals/#{id}")
      _no_task -> ""
    end
  end
end

defmodule Battery.Operations.ProcessTasks do
  @moduledoc """
  The two service tasks around a process's wait for an activation, the way a host's
  `AshBpmn.ActionInvoker` runs them:

    * `submission_activation/1` reads the activation id off the process's subject, a
      `Battery.Operations.Submission`, and answers `activation_id`.
    * `activation_status/1` reads how the provider said the activation stood, from the
      envelope the follow-up wrote for `activation_id`, and answers `status`. A process
      routes on what the provider's READ recorded, not on the webhook that woke it.
  """

  require Ash.Query

  alias Battery.Operations.{ActivationSettled, Submission}

  def submission_activation(ctx) do
    case Ash.get(Submission, ctx[:subject].id) do
      {:ok, %{activation_id: id}} when is_binary(id) -> {:ok, %{"activation_id" => id}}
      {:ok, _no_activation} -> {:error, :no_activation}
      {:error, error} -> {:error, error}
    end
  end

  def activation_status(ctx) do
    id = ctx[:inputs]["activation_id"]

    case ActivationSettled |> Ash.Query.filter(subject == ^id) |> Ash.read() do
      {:ok, [%{data: %{"status" => status}} | _]} -> {:ok, %{"status" => status}}
      {:ok, []} -> {:error, {:activation_not_settled, id}}
      {:error, error} -> {:error, error}
    end
  end
end

defmodule Battery.Execution.CheckConsent do
  @moduledoc """
  `Referral.check_consent`: `%{"consent" => "on_file"}` when the referral's patient
  consent is on file, otherwise the business error `consent_missing`
  (`AshAgent.BusinessError`), an answer a process routes on rather than a fault.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    case Ash.get(Battery.Execution.Referral, input.arguments.id, Ash.Context.to_opts(context)) do
      {:ok, %{consent_on_file?: true}} -> {:ok, %{"consent" => "on_file"}}
      {:ok, _referral} -> {:error, AshAgent.BusinessError.exception(code: "consent_missing")}
      {:error, error} -> {:error, error}
    end
  end
end

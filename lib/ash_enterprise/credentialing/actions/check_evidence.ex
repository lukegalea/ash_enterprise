defmodule AshEnterprise.Credentialing.Actions.CheckEvidence do
  @moduledoc """
  The evidence checks a credentialing process runs side by side before a credential goes
  to the committee: `Credential.check_documents` and `Credential.check_expiry`.

  Each reads the credential as the caller and answers with what it found, or refuses with
  an `AshAgent.BusinessError` whose code a diagram routes on:

    * `:documents` — `licence_document_missing` when no licence document is filed for the
      credential; otherwise `%{"documents_on_file" => n}`.
    * `:expiry` — `expiry_date_missing` when the credential states no expiry date,
      `credential_expired` when that date is today or earlier; otherwise
      `%{"expires_on" => iso_date}`.

  A refusal is an answer, not a fault: the invocation that ran the check fails with
  `failure_class: :business` and is not retried, and the process's error boundary takes
  it (`AshEnterprise.Process.ServiceInvocation`).
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.BusinessError
  alias AshEnterprise.Credentialing

  @impl true
  def run(input, opts, context) do
    with {:ok, credential} <-
           Credentialing.get_credential(
             input.arguments.id,
             Ash.Context.to_opts(context, load: [:licence_documents])
           ) do
      check(Keyword.fetch!(opts, :check), credential)
    end
  end

  defp check(:documents, %{licence_documents: []}), do: refuse("licence_document_missing")

  defp check(:documents, %{licence_documents: documents}),
    do: {:ok, %{"documents_on_file" => length(documents)}}

  defp check(:expiry, %{expires_on: nil}), do: refuse("expiry_date_missing")

  defp check(:expiry, %{expires_on: expires_on}) do
    if Date.after?(expires_on, Date.utc_today()),
      do: {:ok, %{"expires_on" => Date.to_iso8601(expires_on)}},
      else: refuse("credential_expired")
  end

  defp refuse(code), do: {:error, BusinessError.exception(code: code)}
end

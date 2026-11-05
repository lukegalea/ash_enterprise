defmodule AshEnterprise.Credentialing.Actions.RequestDocuments do
  @moduledoc """
  `Credential.request_documents`: the credentialing case asks for the licence document a
  credential lacks. It reads the credential as the caller, then records the request as a
  `document.requested` envelope (`AshEnterprise.Credentialing.DocumentEvent`), whose id is
  the invocation's key: the case's task runs it once per execution however often the task
  is redelivered. Answers with the envelope's id.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Platform.SystemActor

  @source "urn:clinic:credentialing-case"

  @impl true
  def run(input, _opts, context) do
    caller = Ash.Context.to_opts(context)

    with {:ok, credential} <- Credentialing.get_credential(input.arguments.id, caller),
         {:ok, event} <-
           Credentialing.request_document(
             %{
               event_id: event_id(input, credential),
               source: @source,
               subject: credential.id,
               time: DateTime.utc_now(),
               data: %{"kind" => "certificate"}
             },
             actor: SystemActor.oban(),
             tenant: credential.organization_id
           ) do
      {:ok, %{"requested" => event.event_id}}
    end
  end

  # The invocation's key when a case runs this; otherwise a request of its own.
  defp event_id(input, credential) do
    case input.context[:ash_agent] do
      %{invocation_key: key} when is_binary(key) -> key
      _direct -> "request:#{credential.id}:#{Ash.UUIDv7.generate()}"
    end
  end
end

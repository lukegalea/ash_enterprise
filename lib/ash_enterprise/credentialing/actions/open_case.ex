defmodule AshEnterprise.Credentialing.Actions.OpenCase do
  @moduledoc """
  `Credential.open_case`: start the credentialing process for a credential, as the person
  asking (`AshEnterprise.Credentialing.CaseProcess`).

  The credential is read as the caller, and the caller must be one who may change it
  (`Credential.correct`), as opening a case is a clinic coordinator's act. The engine runs
  as the process actor and the caller is the instance's starter, which is who its service
  tasks run as. A case already open for the credential is returned, not started twice.
  Answers with the instance's id and status.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.CaseProcess
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, credential} <- Credentialing.get_credential(input.arguments.record_id, opts),
         :ok <- may_change(credential, context),
         {:ok, instance} <- open(credential, context.actor) do
      {:ok, %{"instance_id" => instance.id, "status" => to_string(instance.status)}}
    end
  end

  defp may_change(credential, context) do
    if Ash.can?({credential, :correct}, context.actor, tenant: context.tenant),
      do: :ok,
      else: {:error, Ash.Error.Forbidden.exception([])}
  end

  defp open(credential, actor) do
    tenant = credential.organization_id

    case CaseProcess.running(credential.id, tenant) do
      nil ->
        with {:ok, definition} <- CaseProcess.definition(tenant) do
          AshBpmn.start_instance(AshEnterprise.Bpmn,
            definition: definition,
            subject: credential,
            actor: SystemActor.process(),
            started_by_id: actor.id,
            tenant: tenant
          )
        end

      instance ->
        {:ok, instance}
    end
  end
end

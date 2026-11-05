defmodule AshEnterprise.Test.Process.EvidenceChecks do
  @moduledoc """
  A clinic whose credentialing process runs its evidence checks as service tasks
  through their invocations (`AshEnterprise.Process.ServiceInvocation`): a tenant, one
  clinician and their credential, the diagrams that check it, and the engine handles a
  test needs to redeliver a node. SYNTHETIC data only.
  """

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Bpmn.{Definition, Instance, Token}
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor

  @doc """
  A tenant whose administrator registered a clinic, a clinician and their licence, valid
  for a year: `%{admin:, tenant:, credential:}`.
  """
  def clinic!(opts \\ []) do
    admin = tenant!()
    as_admin = [actor: admin.actor, tenant: admin.tenant]
    clinic = Credentialing.register_clinic!("Synthetic clinic #{unique()}", as_admin)

    clinician =
      Credentialing.register_clinician!(
        %{
          first_name: "Ada",
          last_name: "Synthetic",
          job_title: "Practice nurse",
          clinic_id: clinic.id
        },
        as_admin
      )

    credential =
      Credentialing.record_credential!(
        %{
          kind: :licence,
          number: "DEMO-RN-#{unique()}",
          expires_on: Keyword.get(opts, :expires_on, Date.add(Date.utc_today(), 365)),
          clinician_id: clinician.id
        },
        as_admin
      )

    %{admin: admin, tenant: admin.tenant, credential: credential}
  end

  @doc "Files a document of `kind` for the clinic's credential."
  def file_document!(clinic, kind) do
    Credentialing.file_licence_document!(
      %{
        kind: kind,
        title: "Synthetic #{kind}",
        document_version_id: Ecto.UUID.generate(),
        credential_id: clinic.credential.id
      },
      actor: clinic.admin.actor,
      tenant: clinic.tenant
    )
  end

  @doc "Publishes `xml` in the clinic's tenant, under a key of its own."
  def publish!(clinic, xml) do
    %{key: "clinic.checks.#{unique()}", name: "Credential checks", xml: xml}
    |> Definition.create!(actor: SystemActor.process(), tenant: clinic.tenant)
    |> Definition.publish!(actor: SystemActor.process(), tenant: clinic.tenant)
  end

  @doc """
  Starts `definition` on the clinic's credential, as a trigger does: the engine acts as
  the process actor, and the administrator is the person who started it.
  """
  def start!(clinic, definition, starter \\ nil) do
    AshBpmn.start_instance!(AshEnterprise.Bpmn,
      definition: definition,
      subject: clinic.credential,
      actor: SystemActor.process(),
      started_by_id: (starter || clinic.admin.user).id,
      tenant: clinic.tenant
    )
  end

  @doc "The only instance of `definition`."
  def instance!(clinic, definition) do
    Instance
    |> Ash.Query.filter(definition_id == ^definition.id)
    |> Ash.read_one!(tenant: clinic.tenant, authorize?: false)
  end

  @doc "The instance's tokens at `node_id`."
  def tokens_at(clinic, instance, node_id) do
    Token
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(tenant: clinic.tenant, authorize?: false)
  end

  @doc "Every invocation in the clinic's tenant, with its result, oldest first."
  def invocations(clinic) do
    Invocation
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.Query.load(:result)
    |> Ash.read!(actor: SystemActor.oban(), tenant: clinic.tenant)
  end

  @doc "The advance job a retry of `token`'s node would run, at `attempt`."
  def retry_job(clinic, instance, token, attempt) do
    %Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: attempt,
      max_attempts: 20,
      args: %{
        "instance_id" => instance.id,
        "token_id" => token.id,
        "node_id" => token.node_id,
        "tenant" => clinic.tenant,
        "domain" => to_string(AshEnterprise.Bpmn)
      }
    }
  end

  defp unique, do: System.unique_integer([:positive])
end

defmodule AshEnterprise.Credentialing.LicenceDemoData do
  @moduledoc """
  The clinic's licence documents and the agent that reads them, for showcase slice 2
  (`/app/showcase/credentialing`, beats 6 to 9). Run by
  `AshEnterprise.Credentialing.DemoData.populate/1` after the clinic exists.

  What it adds:

    * **Two documents per credential**, a certificate and a register extract
      (`AshEnterprise.Credentialing.LicenceDocument`), their text ingested into the
      evidence store as addressed lines. `DEMO-OT-0003`'s bundle is long and its extract
      states two different dates, so reading it runs out of budget and its date finding
      is ambiguous.
    * **An erasure scope for each clinician** (`Clinician.open_erasure_scope`), for a
      clinic registered before clinicians had one.
    * **The clinic's directors**, `ines@example.com` and `omar@example.com`, holding the
      tenant's Administrator role: an agent is published under four eyes, so it takes
      two. Ines asks for the licence reader (`AshEnterprise.Credentialing.LicenceReader`)
      to be published, Omar approves it, and Ines gives the coordinator its start grant.
    * **The Credentialing reader role**, held by the coordinator and the committee: read
      the documents (their tools are generic actions, so the grant reaches every row,
      `:global`) and the findings.
    * **The Credentialing document filer role**, held by the coordinator: file documents.

  Idempotent: every step finds its rows first.

  Everything here is synthetic: the names, numbers, dates and wording are made up.
  """

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{LicenceDocument, LicenceReader}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.DemoData
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.SystemOne.Judgment

  @director "ines@example.com"
  @deputy "omar@example.com"
  @reader_role "Credentialing reader"
  @filer_role "Credentialing document filer"

  # The date each register extract says the licence is valid until; a second date
  # makes the extract disagree with itself.
  @valid_until %{
    "DEMO-PT-0001" => ["2028-06-30"],
    "DEMO-RN-0002" => ["2027-11-30"],
    "DEMO-OT-0003" => ["2027-12-31", "2028-03-31"],
    "DEMO-SLT-0004" => ["2027-09-30"],
    "DEMO-DT-0005" => ["2027-05-31"]
  }

  # The long bundle: conditions the certificate lists, so reading it costs more.
  @long "DEMO-OT-0003"

  @doc """
  Adds the documents, scopes, directors and the published licence reader to the clinic
  `clinic` (`AshEnterprise.Credentialing.DemoData.populate/1`'s result) in `tenant`.
  Returns `%{director:, deputy:, documents:}`.
  """
  @spec populate(Ash.UUID.t(), map()) :: map()
  def populate(tenant, clinic) do
    actor = SystemActor.seed()
    root = DemoData.root_business_unit!(tenant, actor)

    reader =
      DemoData.ensure_role!(
        @reader_role,
        "Reads the clinic's licence documents and what the licence reader found in them.",
        privileges([{LicenceDocument, :read}, {Judgment, :read}]),
        :global,
        root,
        tenant,
        actor
      )

    filer =
      DemoData.ensure_role!(
        @filer_role,
        "Files the documents a credential rests on.",
        privileges([{LicenceDocument, :create}]),
        :global,
        root,
        tenant,
        actor
      )

    for person <- [clinic.coordinator | clinic.committee],
        do: DemoData.ensure_user_role!(person, reader, root, tenant, actor)

    DemoData.ensure_user_role!(clinic.coordinator, filer, root, tenant, actor)

    administrator = administrator_role!(tenant, actor)
    director = director!(@director, administrator, root, tenant, actor)
    deputy = director!(@deputy, administrator, root, tenant, actor)

    as_coordinator = [actor: as_person(clinic.coordinator, tenant), tenant: tenant]

    clinicians = Enum.map(clinic.clinicians, &with_scope!(&1, tenant))
    by_id = Map.new(clinicians, &{&1.id, &1})

    documents =
      for credential <- clinic.credentials,
          kind <- LicenceDocument.kinds(),
          do:
            document!(
              credential,
              Map.fetch!(by_id, credential.clinician_id),
              kind,
              as_coordinator
            )

    published!(director, deputy, tenant)
    start_grant!(director, clinic.coordinator, tenant)

    %{director: director, deputy: deputy, documents: documents}
  end

  @doc "The clinic director's email: asks for the licence reader to be published."
  @spec director_email() :: String.t()
  def director_email, do: @director

  @doc "The deputy director's email: approves the publish."
  @spec deputy_email() :: String.t()
  def deputy_email, do: @deputy

  @doc "The synthetic lines of the `kind` document of a credential numbered `number`."
  @spec lines(atom(), String.t(), String.t()) :: [String.t()]
  def lines(:certificate, number, holder) do
    [
      "SYNTHETIC DOCUMENT, for demonstration only",
      "Riverside Community Clinic",
      "Certificate of registration",
      "Holder: #{holder}",
      "Licence number: #{number}",
      "Issued: 2025-07-01"
    ] ++ conditions(number)
  end

  def lines(:register_extract, number, holder) do
    [dated | later] = Map.fetch!(@valid_until, number)

    [
      "SYNTHETIC DOCUMENT, for demonstration only",
      "Register of practitioners, extract",
      "Name: #{holder}",
      "Licence number: #{number}",
      "Status: registered",
      "Valid until: #{dated}"
    ] ++ Enum.map(later, &"Renewal noted: valid until #{&1}")
  end

  defp conditions(@long) do
    for n <- 1..12,
        do: "Condition #{n}: supervised practice in setting #{n}, reviewed every #{n + 2} months"
  end

  defp conditions(_number), do: []

  # --- clinicians ------------------------------------------------------------------

  defp with_scope!(%{erasure_scope_id: id} = clinician, _tenant) when is_binary(id),
    do: clinician

  defp with_scope!(clinician, tenant),
    do:
      Credentialing.open_clinician_erasure_scope!(clinician,
        actor: SystemActor.seed(),
        tenant: tenant
      )

  # --- documents -------------------------------------------------------------------

  defp document!(credential, clinician, kind, opts) do
    existing =
      Credentialing.list_licence_documents!(
        Keyword.put(opts, :query, filter: [credential_id: credential.id, kind: kind])
      )

    case existing do
      [document | _] ->
        document

      [] ->
        holder = "#{clinician.first_name} #{clinician.last_name}"
        version = evidence!(lines(kind, credential.number, holder), opts[:tenant])

        Credentialing.file_licence_document!(
          %{
            kind: kind,
            title: "#{credential.number} #{title(kind)}",
            document_version_id: version,
            credential_id: credential.id
          },
          opts
        )
    end
  end

  defp title(:certificate), do: "certificate"
  defp title(:register_extract), do: "register extract"

  # The evidence store keys a document by its content's hash across every tenant, so the
  # tenant is part of the content.
  defp evidence!(lines, tenant) do
    bytes = Enum.join(["SYNTHETIC clinic #{tenant}" | lines], "\n")
    sha256 = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    case existing_version(sha256) do
      %{id: id} ->
        id

      nil ->
        version = AshEvidence.Domain.ingest_document!("text", bytes, sha256)
        run = AshEvidence.Domain.start_parse_run!(version.id, "clinic-demo")

        lines
        |> Enum.with_index(1)
        |> Enum.each(fn {text, seq} ->
          AshEvidence.Domain.ingest_atom!(version.id, run.id, seq, text, :line)
        end)

        AshEvidence.Domain.mark_parse_run_ok!(run)
        version.id
    end
  end

  # The evidence store has no tenancy and no policies.
  defp existing_version(sha256) do
    AshEvidence.DocumentVersion
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read_one!()
  end

  # --- directors, publishing, the start grant -------------------------------------

  defp administrator_role!(tenant, actor) do
    Security.Role
    |> Ash.Query.filter(name == "Administrator")
    |> Ash.read_one!(actor: actor, tenant: tenant)
  end

  defp director!(email, role, root, tenant, actor) do
    user = DemoData.ensure_user!(email, root, tenant)
    DemoData.ensure_user_role!(user, role, root, tenant, actor)
    user
  end

  # The director asks, the deputy approves, and the publish runs as the job runner runs
  # it: the same path an administrator's request takes in the application.
  defp published!(director, deputy, tenant) do
    oban = [actor: SystemActor.oban(), tenant: tenant]

    case Execution.latest_published_agent_version(LicenceReader.key(),
           authorize?: false,
           tenant: tenant
         ) do
      {:ok, %{} = version} ->
        version

      _none ->
        as_director = [actor: as_person(director, tenant), tenant: tenant]
        draft = Execution.register_agent_from_code!(LicenceReader, as_director)

        %{"invocation_id" => id} =
          Execution.request_agent_publish!(draft.id, %{}, as_director)

        row = Execution.get_invocation!(id, authorize?: false, tenant: tenant)
        task = Ash.load!(row, :approval_task, authorize?: false).approval_task

        HumanTask
        |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
          actor: as_person(deputy, tenant),
          tenant: tenant
        )
        |> Ash.run_action!()

        Execution.apply_invocation_decision!(row, oban)
        {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban)
        Execution.get_agent_version!(draft.id, authorize?: false, tenant: tenant)
    end
  end

  defp start_grant!(director, person, tenant) do
    key = LicenceReader.key()
    id = person.id

    existing =
      Security.AgentStartGrant
      |> Ash.Query.filter(agent_key == ^key and principal_id == ^id)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    existing ||
      Security.AgentStartGrant.grant!(
        %{agent_key: key, principal_id: id, principal_type: :user},
        actor: as_person(director, tenant),
        tenant: tenant
      )
  end

  defp as_person(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp privileges(wanted) do
    wanted = MapSet.new(wanted, fn {resource, verb} -> {inspect(resource), verb} end)

    Security.Privilege
    |> Ash.read!(actor: SystemActor.seed())
    |> Enum.filter(&MapSet.member?(wanted, {&1.resource_name, &1.access_right}))
  end
end

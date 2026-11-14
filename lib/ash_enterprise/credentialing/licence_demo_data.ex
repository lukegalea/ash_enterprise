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
  alias AshEnterprise.Credentialing.{LicenceDocument, LicenceReader, ReleaseDemoData}
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
  @spec populate(Ash.UUID.t(), map(), String.t()) :: map()
  def populate(tenant, clinic, password) do
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
    director = director!(@director, administrator, root, tenant, actor, password)
    deputy = director!(@deputy, administrator, root, tenant, actor, password)

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
    start_grant!(director, director, tenant)

    release = ReleaseDemoData.populate(tenant, director, deputy)

    %{director: director, deputy: deputy, documents: documents, release: release}
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
            # Not the number: a title is as visible as the document, and the number is a
            # secured column (ADR 0073).
            title: "#{holder} #{title(kind)}",
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

  defp director!(email, role, root, tenant, actor, password) do
    user = DemoData.ensure_user!(email, root, tenant, password)
    DemoData.ensure_user_role!(user, role, root, tenant, actor)
    user
  end

  # The director asks, the deputy approves, and the publish runs as the job runner runs
  # it: the same path an administrator's request takes in the application.
  defp published!(director, deputy, tenant) do
    case Execution.latest_published_agent_version(LicenceReader.key(),
           authorize?: false,
           tenant: tenant
         ) do
      {:ok, %{} = version} -> version
      _none -> publish!(LicenceReader, director, deputy, tenant)
    end
  end

  @doc """
  Publishes the agent declared in `agent` in `tenant`: `director` registers it and asks,
  `deputy` approves, and the publish runs as the job runner runs it. Returns the version.
  """
  @spec publish!(module(), struct(), struct(), Ash.UUID.t()) :: struct()
  def publish!(agent, director, deputy, tenant) do
    as_director = [actor: as_person(director, tenant), tenant: tenant]
    draft = Execution.register_agent_from_code!(agent, as_director)
    %{"invocation_id" => id} = Execution.request_agent_publish!(draft.id, %{}, as_director)
    decide!(id, deputy, tenant)
    Execution.get_agent_version!(draft.id, authorize?: false, tenant: tenant)
  end

  @doc """
  `deputy` approves the invocation `id`, and the job runner applies the decision and runs
  it: what an approval does in the application.
  """
  @spec decide!(Ash.UUID.t(), struct(), Ash.UUID.t()) :: :ok
  def decide!(id, deputy, tenant) do
    oban = [actor: SystemActor.oban(), tenant: tenant]
    row = Execution.get_invocation!(id, authorize?: false, tenant: tenant)
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: as_person(deputy, tenant),
      tenant: tenant
    )
    |> Ash.run_action!()

    Execution.apply_invocation_decision!(row, oban)
    :succeeded = run!(row.id, tenant, oban)
    :ok
  end

  # The demo task boots the whole application, so a running queue may claim the row before
  # this process does, and then `execute/3` here ends `:skipped`. That says only that another
  # worker holds it: wait for that worker's outcome, and take nothing but `:succeeded` as done.
  defp run!(id, tenant, oban, rounds \\ 120)

  defp run!(id, _tenant, _oban, 0), do: raise("invocation #{id} did not settle")

  defp run!(id, tenant, oban, rounds) do
    case Executor.execute(Invocation, id, oban) do
      {:ok, :skipped} ->
        case Execution.get_invocation!(id, authorize?: false, tenant: tenant).status do
          :succeeded ->
            :succeeded

          status when status in [:ready, :executing] ->
            Process.sleep(250)
            run!(id, tenant, oban, rounds - 1)

          status ->
            raise "invocation #{id} ended #{status}"
        end

      {:ok, :succeeded} ->
        :succeeded

      other ->
        raise "invocation #{id} ended #{inspect(other)}"
    end
  end

  @doc "The person with `email` in `tenant`."
  @spec user!(String.t(), Ash.UUID.t()) :: struct()
  def user!(email, tenant) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
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

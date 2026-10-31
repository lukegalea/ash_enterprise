defmodule AshEnterprise.Credentialing.DemoData do
  @moduledoc """
  The synthetic clinic (`mix ash_enterprise.demo`): one clinic, five clinicians with a
  credential each, a coordinator who registers them and asks for activations, and a
  two-person credentialing committee to approve them.

  The credentials are in several states, so the clinic is not empty on arrival:

  | Credential | State |
  |---|---|
  | `DEMO-PT-0001`, `DEMO-RN-0002`, `DEMO-OT-0003` | pending: nobody has asked to activate them |
  | `DEMO-SLT-0004` | the coordinator asked; it waits for a committee member's approval |
  | `DEMO-DT-0005` | the coordinator asked and a committee member rejected it |

  The requests go through `AshEnterprise.Execution.invoke/4` as the coordinator, under
  fixed keys (`clinic-demo:activate:<number>`) so re-running finds them, and the
  decision through the approval task's reject door as a committee member, so they are
  what the application would have recorded; the rejection is applied as the
  `:apply_decision` job applies it. Nothing
  here runs an activation: that needs a committee member's approval, which the showcase
  tour (`/app/showcase/credentialing`) walks through.

  | Who | Role | May |
  |---|---|---|
  | `rosa@example.com` | Credentialing coordinator | register clinics, clinicians and credentials; activate a credential |
  | `rosa@example.com` | Credentialing requester | read the activation requests she owns |
  | `kenji@example.com`, `amaka@example.com` | Credentialing committee | read the clinic's records |

  The coordinator and committee roles grant at `:global` depth: the clinic is the
  tenant's whole credentialing practice, and `lookup_activation`, a generic action, is
  reachable only through a grant that reaches every row. The requester role grants at
  `:basic`, the holder's own rows: the coordinator follows her requests, not the
  tenant's other invocations. A committee member reads a request while it waits for
  their decision, through the approval candidacy.

  The clinic's records are created as the coordinator, through the same actions the
  application exposes, so the coordinator owns them. Everything here is illustrative:
  the names, numbers and dates are made up.

  Idempotent by name: each step finds its own rows before creating them, so re-running
  it changes nothing.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Clinic, Clinician, Credential}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Invocation}
  alias AshEnterprise.Platform.DemoData
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @coordinator "rosa@example.com"
  @committee ["kenji@example.com", "amaka@example.com"]
  @coordinator_role "Credentialing coordinator"
  @requester_role "Credentialing requester"

  @clinic "Riverside Community Clinic"

  # {first name, last name, job title, credential kind, credential number}
  @clinicians [
    {"Imogen", "Hale", "Physiotherapist", :licence, "DEMO-PT-0001"},
    {"Tariq", "Osei", "Practice nurse", :licence, "DEMO-RN-0002"},
    {"Wen", "Larsson", "Occupational therapist", :certification, "DEMO-OT-0003"},
    {"Noor", "Haddad", "Speech and language therapist", :licence, "DEMO-SLT-0004"},
    {"Mateo", "Ruiz", "Dietitian", :certification, "DEMO-DT-0005"}
  ]

  # The seeded requests: {credential number, the committee's decision or nil}.
  @requests [{"DEMO-SLT-0004", nil}, {"DEMO-DT-0005", :reject}]

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"

  @doc """
  Populates `organization_id`'s tenant with the clinic. Returns the people and records
  that now exist: `%{coordinator:, committee:, clinic:, clinicians:, credentials:,
  requests:}`, the credentials in the order of the table above and `requests` the
  seeded invocations.
  """
  @spec populate(Ash.UUID.t()) :: map()
  def populate(organization_id) do
    actor = SystemActor.seed()
    tenant = organization_id
    root = DemoData.root_business_unit!(tenant, actor)

    coordinator_role =
      DemoData.ensure_role!(
        @coordinator_role,
        "Registers the clinic's clinicians and their credentials, and asks for activations.",
        privileges(read: :all, create: :all, write: [Credential]),
        :global,
        root,
        tenant,
        actor
      )

    committee_role =
      DemoData.ensure_role!(
        "Credentialing committee",
        "Reviews credential activations; a member never approves their own request.",
        privileges(read: :all),
        :global,
        root,
        tenant,
        actor
      )

    # The coordinator follows their own requests: invocations they own, and no others.
    requester_role =
      DemoData.ensure_role!(
        @requester_role,
        "Follows the activation requests they asked for, and no one else's.",
        privileges(read: [Invocation]),
        :basic,
        root,
        tenant,
        actor
      )

    coordinator = person!(@coordinator, coordinator_role, root, tenant, actor)
    DemoData.ensure_user_role!(coordinator, requester_role, root, tenant, actor)
    committee = Enum.map(@committee, &person!(&1, committee_role, root, tenant, actor))

    as_coordinator = [actor: as_person(coordinator, tenant), tenant: tenant]
    clinic = clinic!(as_coordinator)

    {clinicians, credentials} =
      @clinicians
      |> Enum.map(&clinician_with_credential!(&1, clinic, as_coordinator))
      |> Enum.unzip()

    by_number = Map.new(credentials, &{&1.number, &1})

    requests =
      for {number, decision} <- @requests,
          do: request!(Map.fetch!(by_number, number), decision, as_coordinator, hd(committee))

    %{
      coordinator: coordinator,
      committee: committee,
      clinic: clinic,
      clinicians: clinicians,
      credentials: credentials,
      requests: requests
    }
  end

  @doc "The coordinator's email: the person who asks for activations."
  @spec coordinator_email() :: String.t()
  def coordinator_email, do: @coordinator

  @doc "The name of the role the coordinator asks for activations under."
  @spec coordinator_role() :: String.t()
  def coordinator_role, do: @coordinator_role

  @doc "The key the seed asks to activate the credential numbered `number` under."
  @spec request_key(String.t()) :: String.t()
  def request_key(number), do: "clinic-demo:activate:" <> number

  # The coordinator's request, under a fixed key so asking again finds the same row,
  # and the committee's decision on it when there is one, applied as the
  # `:apply_decision` job would apply it.
  defp request!(credential, decision, as_coordinator, member) do
    row =
      Execution.invoke!(
        @activate,
        %{"id" => credential.id},
        %{key: request_key(credential.number)},
        as_coordinator
      )

    if decision && row.status == :awaiting_approval do
      decide!(row, decision, member, as_coordinator[:tenant])
    else
      row
    end
  end

  # The member's context is built after the request, so it holds the task the request
  # opened (an `ActorContext` is a snapshot of what its person may decide).
  defp decide!(row, decision, member, tenant) do
    as_member = [actor: as_person(member, tenant), tenant: tenant]

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^row.id and node_id == ^Approval.key())
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    if task.status in [:open, :claimed] do
      HumanTask
      |> Ash.ActionInput.for_action(decision, %{record_id: task.id}, as_member)
      |> Ash.run_action!()
    end

    Execution.apply_invocation_decision!(row, actor: SystemActor.oban(), tenant: tenant)
  end

  defp person!(email, role, root, tenant, actor) do
    user = DemoData.ensure_user!(email, root, tenant)
    DemoData.ensure_user_role!(user, role, root, tenant, actor)
    user
  end

  defp as_person(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  # The catalogue's privileges on the three credentialing resources, per verb: `:all`
  # of them, or the listed ones.
  defp privileges(by_verb) do
    resources = [Clinic, Clinician, Credential]

    wanted =
      for {verb, which} <- by_verb,
          resource <- if(which == :all, do: resources, else: which),
          into: MapSet.new(),
          do: {inspect(resource), verb}

    Security.Privilege
    |> Ash.read!(actor: SystemActor.seed())
    |> Enum.filter(&MapSet.member?(wanted, {&1.resource_name, &1.access_right}))
  end

  defp clinic!(opts) do
    case Credentialing.list_clinics!(Keyword.put(opts, :query, filter: [name: @clinic])) do
      [clinic | _] -> clinic
      [] -> Credentialing.register_clinic!(@clinic, opts)
    end
  end

  defp clinician_with_credential!({first, last, title, kind, number}, clinic, opts) do
    credential =
      Credentialing.list_credentials!(Keyword.put(opts, :query, filter: [number: number]))
      |> List.first()

    if credential do
      {Ash.load!(credential, :clinician, opts).clinician, credential}
    else
      clinician =
        Credentialing.register_clinician!(
          %{first_name: first, last_name: last, job_title: title, clinic_id: clinic.id},
          opts
        )

      credential =
        Credentialing.record_credential!(
          %{
            kind: kind,
            number: number,
            expires_on: Date.add(Date.utc_today(), 730),
            clinician_id: clinician.id
          },
          opts
        )

      {clinician, credential}
    end
  end
end

defmodule AshEnterprise.Credentialing.DemoData do
  @moduledoc """
  The synthetic clinic (`mix ash_enterprise.demo`): one clinic, three clinicians with a
  credential each waiting to be activated, a coordinator who registers them and asks for
  activations, and a two-person credentialing committee to approve them.

  | Who | Role | May |
  |---|---|---|
  | `rosa@example.com` | Credentialing coordinator | register clinics, clinicians and credentials; activate a credential |
  | `kenji@example.com`, `amaka@example.com` | Credentialing committee | read the clinic's records |

  Both roles grant at `:global` depth: the clinic is the tenant's whole credentialing
  practice, and `lookup_activation`, a generic action, is reachable only through a
  grant that reaches every row.

  The clinic's records are created as the coordinator, through the same actions the
  application exposes, so the coordinator owns them. Everything here is illustrative:
  the names, numbers and dates are made up.

  Idempotent by name: each step finds its own rows before creating them, so re-running
  it changes nothing.
  """

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Clinic, Clinician, Credential}
  alias AshEnterprise.Platform.DemoData
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @coordinator "rosa@example.com"
  @committee ["kenji@example.com", "amaka@example.com"]

  @clinic "Riverside Community Clinic"

  # {first name, last name, job title, credential kind, credential number}
  @clinicians [
    {"Imogen", "Hale", "Physiotherapist", :licence, "DEMO-PT-0001"},
    {"Tariq", "Osei", "Practice nurse", :licence, "DEMO-RN-0002"},
    {"Wen", "Larsson", "Occupational therapist", :certification, "DEMO-OT-0003"}
  ]

  @doc """
  Populates `organization_id`'s tenant with the clinic. Returns the people and records
  that now exist: `%{coordinator:, committee:, clinic:, clinicians:, credentials:}`.
  """
  @spec populate(Ash.UUID.t()) :: map()
  def populate(organization_id) do
    actor = SystemActor.seed()
    tenant = organization_id
    root = DemoData.root_business_unit!(tenant, actor)

    coordinator_role =
      DemoData.ensure_role!(
        "Credentialing coordinator",
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

    coordinator = person!(@coordinator, coordinator_role, root, tenant, actor)
    committee = Enum.map(@committee, &person!(&1, committee_role, root, tenant, actor))

    as_coordinator = [actor: as_person(coordinator, tenant), tenant: tenant]
    clinic = clinic!(as_coordinator)

    {clinicians, credentials} =
      @clinicians
      |> Enum.map(&clinician_with_credential!(&1, clinic, as_coordinator))
      |> Enum.unzip()

    %{
      coordinator: coordinator,
      committee: committee,
      clinic: clinic,
      clinicians: clinicians,
      credentials: credentials
    }
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

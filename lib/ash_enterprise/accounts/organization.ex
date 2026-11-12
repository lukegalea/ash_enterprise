defmodule AshEnterprise.Accounts.Organization do
  @moduledoc """
  A tenant. Every other row in the system belongs to exactly one of these.

  ## Why this is hand-written

  The Dataverse `organization` table has **505 columns** — verified by the
  scraper, see `priv/cdm/resolved/dataverse_organization.json`. It is a singleton
  settings table holding every org-wide preference: fiscal calendar, email
  behaviour, feature switches, audit toggles, formatting defaults.

  Generating that would produce 505 attributes of noise for the dozen that
  matter. So this is the one entity we deliberately transcribe by hand, taking
  the identity and defaults fields and leaving the settings surface for later —
  when a specific setting is actually needed, add that column and cite it.

  This is the "delete the 80% you do not need" step from
  `docs/manifesto/02-schema-commons.md` taken to its limit.

  ## Why it is not itself multi-tenant

  It *is* the tenant. `tenant?: false` here is not an opt-out of the platform's
  tenancy model — it is the base case of it. Every other resource carries an
  `organization_id` pointing at one of these rows.

  Likewise `ownership: :organization_owned`: in Dataverse this table is
  OrganizationOwned, so only Organization/None access levels are meaningful.
  Nobody "owns" the tenant.

  ## The approval posture

  This row carries the tenant's approval posture through
  `AshAgent.Approval.PostureFragment` — which person decides an approval
  (`AshAgent.Approval.Posture`), and when an `:implementation` posture ends.
  It is set through `set_approval_posture`, a person's own act
  (`human_only`, `changes_authority`) by one of the organization's
  administrators or the platform operator, and answered to the package through
  `AshEnterprise.Execution.Authority`. Lowering it (away from `:standard`)
  needs the sole administrator, the operator, or a change approved under four
  eyes (`posture_floor?: true` below): the fragment's validation decides, and
  refuses with `AshAgent.Approval.PostureChangeRefused`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    api_type: :organization,
    ownership: :organization_owned,
    tenant?: false,
    cdm_entity: "Organization",
    human_only: [:set_approval_posture],
    changes_authority: [:set_approval_posture],
    extra_grants: [AshEnterprise.Security.Checks.PostureOperator],
    extra_extensions: [AshAgent.Effects],
    fragments: [AshAgent.Approval.PostureFragment]

  postgres do
    table "organizations"
    repo AshEnterprise.Repo
  end

  # What the approval-posture rules ask this host: who answers for the posture
  # (`AshEnterprise.Execution.Authority`), who maps an actor to the person
  # deciding (`AshEnterprise.Execution.Identity`), and the resource whose
  # invocations may carry an approved posture change (this host's, whose
  # `set_approval_posture` declaration below is four eyes at the floor).
  approval_posture do
    authority(AshEnterprise.Execution.Authority)
    execution_identity(AshEnterprise.Execution.Identity)
    invocation(AshEnterprise.Execution.Invocation)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 160
      description "Display name of the tenant."
    end

    attribute :unique_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 80, match: ~r/^[a-z0-9][a-z0-9\-]*$/

      description """
      Stable, URL-safe identifier. Used in subdomains and tenant routing, so it
      is immutable once set -- renaming would break every existing link.
      """
    end

    attribute :languagelocale_id, :uuid do
      public? true
      description "Default locale for users who have not chosen one."
    end

    attribute :base_currency_id, :uuid do
      public? true

      description """
      The tenant's reporting currency. Dataverse stores every monetary value
      twice -- once in the transaction currency and once converted to this one --
      so that cross-currency reporting does not have to join exchange rates.
      """
    end

    # First-party (no CDM column): ADR 0042 requires the disclosure control
    # for data leaving a zone to be an opt-in, recorded per tenant. Recorded
    # means data -- this column -- not config, and the update that flips it
    # lands in the audit event log like any other. Read by
    # `AshEnterprise.Zones.ResidencyPolicy`, next to the inference client.
    # Not public: it is a governance record, not part of the organization's
    # API surface.
    attribute :sub_processor_opt_in, :boolean do
      allow_nil? false
      default false
      public? false

      description """
      Whether this tenant has recorded an opt-in to customer-confidential
      data flowing to an instrument outside every declared zone (a
      sub-processor). Default false, and `AshEnterprise.Zones.ResidencyPolicy`
      treats absence, unknown tenants and read failures as false: no tenant
      opts in by silence. ADR 0042.
      """
    end

    # The approval posture and its end date come from the
    # `AshAgent.Approval.PostureFragment` fragment.
  end

  identities do
    # Deliberately `all_tenants?` is irrelevant here: this resource is not
    # tenant-scoped, so the uniqueness is genuinely global.
    identity :unique_name, [:unique_name]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :name,
      :unique_name,
      :languagelocale_id,
      :base_currency_id,
      :sub_processor_opt_in
    ]

    create :create do
      primary? true
      description "Provision a tenant. See AshEnterprise.Accounts.Provisioning for the full flow."
    end

    update :update do
      primary? true
      # unique_name is immutable -- see the attribute description.
      accept [:name, :languagelocale_id, :base_currency_id, :sub_processor_opt_in]
    end

    # `set_approval_posture` comes from the `AshAgent.Approval.PostureFragment`
    # fragment: the posture and its end date, and the fragment's validation of
    # who may change them. What the host adds is who may reach it at all —
    # the policy below — and that it is a person's own act.
  end

  policies do
    # Organization is not tenant-scoped, so a `:global` write grant reaches
    # every tenant's row. This action is an organization's decision about its
    # own approvals: the row must be the actor's own organization, unless the
    # actor is the platform operator, who may set any tenant's posture. A
    # tenancy boundary in place of the data layer's, in addition to the grant
    # union that authorizes the write; it takes nothing from any other action.
    policy action(:set_approval_posture) do
      authorize_if AshEnterprise.Security.Checks.OwnOrganization
      authorize_if AshEnterprise.Security.Checks.PostureOperator
    end
  end

  code_interface do
    define :create
    define :read
    define :by_unique_name, action: :read, get_by: [:unique_name]

    define :set_approval_posture,
      action: :set_approval_posture,
      args: [:approval_posture]
  end

  # Lowering the posture through an invocation is four eyes under every
  # posture (`posture_floor?: true`): the approval behind it can never be a
  # self-approval the current posture would allow. Reached through `invoke`
  # (`AshEnterprise.Execution`); the action is NOT behind
  # `AshAgent.Validations.Governed`, because the sole administrator's and the
  # operator's direct changes must reach it too — the fragment's validation
  # verifies the invocation itself
  # (`AshAgent.Approval.Validations.PostureChange`).
  effects do
    action :set_approval_posture,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :administrator,
      posture_floor?: true,
      intent: :approve
  end
end

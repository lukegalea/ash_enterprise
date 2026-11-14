defmodule AshEnterprise.Accounts.Team do
  @moduledoc """
  A group of users, and — depending on its type — either a principal that can own
  records and hold roles, or a lightweight bucket for sharing.

  ## The type distinction is not cosmetic

  `team_type` comes straight from Dataverse's option set (verified in
  `priv/cdm/resolved/dataverse_team.json`) and it changes what the team *is*:

    * `:owner` — can own records and be assigned security roles. Members inherit
      those roles. This is the expensive, powerful kind.
    * `:access` — **cannot** own records and **cannot** hold roles. Users get
      access purely because a record was shared with the team and they are a
      member. Dataverse's own guidance is that access teams are *more performant*
      precisely because of those two restrictions — there is no role resolution
      to do.
    * `:security_group` / `:office_group` — membership is mirrored from an
      external directory (Entra ID) rather than managed here.

  Getting this wrong is a security bug in both directions: making everything an
  owner team means role resolution has to walk every team a user belongs to, and
  treating an owner team as an access team silently drops inherited privileges.
  So the constraint is enforced, not just documented — see the validations below.

  ## Default teams

  Every business unit gets exactly one system-managed team containing all its
  users. Dataverse maintains these automatically and forbids editing membership
  directly (`is_default` + `system_managed`), because the membership *is* the
  business unit's user list. Same here.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    api_type: :team,
    ownership: :business_owned,
    cdm_entity: "Team",
    extra_extensions: [AshAgent.Effects],
    # Restoring a deleted team is a person's decision (ADR 0059), and it can bring back
    # the roles an owner team carries, so no automation principal's grant reaches it
    # either (ADR 0043).
    human_only: [:restore],
    changes_authority: [:restore]

  postgres do
    table "teams"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 160
    end

    attribute :description, :string do
      public? true
      constraints max_length: 2000
    end

    attribute :team_type, AshEnterprise.Accounts.Types.TeamType do
      allow_nil? false
      default :owner
      public? true

      description "See the moduledoc: this decides whether the team can own records and hold roles."
    end

    attribute :is_default, :boolean do
      allow_nil? false
      default false
      public? true
      writable? false
      description "The business unit's automatic all-users team. Membership is system-managed."
    end

    attribute :system_managed, :boolean do
      allow_nil? false
      default false
      public? true
      writable? false

      description "Membership is maintained by the platform or an external directory, not by hand."
    end

    attribute :external_directory_object_id, :uuid do
      public? true

      description """
      The Entra ID (Azure AD) group object id, for :security_group and
      :office_group teams whose membership is mirrored from the directory.
      """
    end
  end

  relationships do
    belongs_to :administrator, AshEnterprise.Accounts.User do
      public? true
      attribute_writable? true
      description "The user responsible for the team. Dataverse marks this SystemRequired."
    end

    has_many :team_memberships, AshEnterprise.Accounts.TeamMembership do
      public? true
    end

    many_to_many :users, AshEnterprise.Accounts.User do
      through AshEnterprise.Accounts.TeamMembership
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :user_id
      public? true
    end
  end

  identities do
    identity :unique_name_per_business_unit, [:owning_business_unit_id, :name]
  end

  validations do
    validate present(:external_directory_object_id),
      where: [attribute_in(:team_type, [:security_group, :office_group])],
      message: "directory-backed teams must reference an external group"
  end

  # A deleted team is archived, not removed, and `:archived` is the one read that sees it:
  # every other read filters archived rows out.
  archive do
    exclude_read_actions([:archived])
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :description, :team_type, :administrator_id, :owning_business_unit_id]

    # What the JSON:API index and the GraphQL list serve. Paging is required, so a
    # request that names no page gets the first 50 rows and a link to the next, never
    # the table, and no requested page is larger than 250. The primary `:read` stays
    # unpaged for internal callers.
    read :list do
      description "Teams, a page at a time: 50 by default, 250 at most."

      pagination keyset?: true,
                 offset?: true,
                 required?: true,
                 countable: true,
                 default_limit: 50,
                 max_page_size: 250
    end

    read :archived do
      description "Deleted (archived) teams, the ones `:restore` can bring back."
      filter expr(not is_nil(archived_at))
    end

    update :restore do
      description """
      Undo a delete: clear `archived_at` on a team archived within the restore window
      (`AshEnterprise.Platform.Validations.WithinRestoreWindow`, 30 days by default).
      Human-only, and audited like any update.
      """

      accept []
      # Non-atomic: the window is checked against the archived row as loaded (through
      # `:archived`, since every other read hides it), and audited updates are non-atomic
      # anyway (the ash_events wrapper).
      require_atomic? false

      validate AshEnterprise.Platform.Validations.WithinRestoreWindow
      change set_attribute(:archived_at, nil)
      # `metadata.role_names`: the roles the team's members hold through it again.
      change {AshEnterprise.Security.Changes.StampTeamGrant, as: :restore}
    end

    create :create do
      primary? true
    end

    update :update do
      primary? true
      # team_type is immutable. Changing an owner team to an access team would
      # strip inherited roles from every member without touching any role row,
      # which is invisible in an audit of role assignments. Delete and recreate
      # instead, so the change is explicit.
      accept [:name, :description, :administrator_id]
    end

    create :create_default_for_business_unit do
      description """
      Creates the system-managed all-users team for a business unit. Called by
      the business-unit provisioning flow, not by hand.
      """

      accept [:name, :owning_business_unit_id]
      change set_attribute(:is_default, true)
      change set_attribute(:system_managed, true)
      change set_attribute(:team_type, :owner)
    end
  end

  # Exposed as an ash_ai tool (`list_teams`); ADR 0057.
  effects do
    action :read,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end

  calculations do
    calculate :can_own_records, :boolean, expr(team_type == :owner) do
      public? true
      description "Only owner teams may appear in a record's owner_id."
    end

    calculate :can_hold_roles,
              :boolean,
              expr(team_type in [:owner, :security_group, :office_group]) do
      public? true

      description """
      Access teams cannot hold security roles -- that restriction is what makes
      them cheap. Directory-backed teams can, so an Entra group can be granted a
      role centrally.
      """
    end
  end

  code_interface do
    define :create
    define :read
    define :create_default_for_business_unit
  end
end

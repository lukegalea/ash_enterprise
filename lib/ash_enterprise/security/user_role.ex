defmodule AshEnterprise.Security.UserRole do
  @moduledoc """
  Assigns a role to a user, **scoped to a business unit**.

  This is the resource the agent console mutates when someone says *"assign the
  admin role to user XYZ"* — see `docs/manifesto/05-agents-are-users.md`.

  ## Why the scoping business unit is a column

  Dataverse's modern ("matrix") business-unit model lets a user hold a role from a
  business unit other than their own, and the grant is then evaluated relative to
  **that** unit. So an assignment is genuinely a triple:

      (user, role, scoping_business_unit)

  A regional manager can hold "Sales Manager" scoped to EMEA and "Sales Reader"
  scoped to APAC, and the `:deep` grants in each resolve against a different
  subtree.

  The column exists from the first commit deliberately. Deriving scope from
  `user.owning_business_unit_id` instead would work until the first customer needs
  cross-unit access, and then there is no migration: the intent of every existing
  assignment is unrecoverable, because "scoped to their own unit" and "scoped to
  the unit they happened to be in when assigned" are indistinguishable after the
  fact.

  Defaulting it to the user's own business unit keeps the simple case simple.

  ## Assigning a role through approval

  `assign_governed` is the same assignment as `assign`, behind its invocation
  (ADR 0055): it runs only when `AshEnterprise.Execution.Invocation` runs it, after an
  administrator other than the requester approved it (`AshAgent.Validations.Governed`
  refuses every other call). `request_assignment` asks for it through `invoke` and
  returns the request with its approval link; it is the MCP `assign_role` tool, so a
  model asking for a role changes nothing until a second person approves.

  `assign` stays ungoverned for the callers that have not moved to `invoke` yet: the
  tenant seeder, the demo data, the access-request process, the assistant's
  confirmed proposals, the admin UI and test fixtures.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false,
    self_service: [:request_assignment],
    changes_authority: [:assign, :assign_governed, :destroy],
    extra_extensions: [AshAgent.Effects]

  postgres do
    table "user_roles"
    repo AshEnterprise.Repo

    references do
      reference :user, on_delete: :delete
      reference :role, on_delete: :delete
      reference :scoping_business_unit, on_delete: :restrict
    end

    # `assign` upserts on this identity, so its index must cover only assignments in
    # force, or re-assigning a revoked role would update the archived row and leave it
    # revoked.
    identity_wheres_to_sql unique_assignment: "archived_at IS NULL"
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :user, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :role, AshEnterprise.Security.Role do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :scoping_business_unit, AshEnterprise.Accounts.BusinessUnit do
      allow_nil? false
      public? true
      attribute_writable? true

      description """
      The business unit this grant is evaluated relative to. Defaults to the
      user's own unit.
      """
    end
  end

  identities do
    # The same role may be held twice by one user if scoped to different units --
    # that is the feature, not a duplicate. Only assignments in force count: a revoked
    # (archived) one stays as history, and the role can be assigned again.
    identity :unique_assignment, [:user_id, :role_id, :scoping_business_unit_id],
      where: expr(is_nil(archived_at))
  end

  # `history` reads archived rows too (`AshEnterprise.Execution.Approval`).
  archive do
    exclude_read_actions([:history])
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:user_id, :role_id, :scoping_business_unit_id]

    read :history do
      description "Every assignment, in force or revoked (archived): who has ever held a role."
    end

    create :assign do
      primary? true
      upsert? true
      upsert_identity :unique_assignment

      description """
      Idempotent. Assigning a role someone already holds is the same intent twice,
      not an error -- which matters when an agent or a directory sync is the caller.
      """

      change AshEnterprise.Security.Changes.DefaultScopingBusinessUnit
    end

    create :assign_governed do
      upsert? true
      upsert_identity :unique_assignment
      # Defaulted by the change below, so a request may leave it out.
      allow_nil_input [:scoping_business_unit_id]

      description """
      `assign`, run only by its invocation, once an administrator other than the
      requester approved it. Request it with `request_assignment` or `invoke`.
      """

      validate {AshAgent.Validations.Governed, invocation: AshEnterprise.Execution.Invocation}
      change AshEnterprise.Security.Changes.DefaultScopingBusinessUnit
    end

    action :request_assignment, :map do
      description """
      Ask for a security role to be assigned to a user, scoped to a business unit (the
      user's own when none is given). Nothing changes until an administrator other than
      you approves it: the result is the request, with its status and the link where it
      waits for approval.
      """

      argument :user_id, :uuid, allow_nil?: false, public?: true
      argument :role_id, :uuid, allow_nil?: false, public?: true
      argument :scoping_business_unit_id, :uuid, public?: true

      run {AshEnterprise.Execution.Actions.RequestInvocation, target: :assign_governed}
    end
  end

  # Exposed as ash_ai tools (ADR 0057). Granting a role is a second person's
  # call, so `assign` and `assign_governed` declare four-eyes approval by an
  # administrator, which the governed path reads; only `assign_governed` is
  # kept behind its invocation (see the moduledoc). `request_assignment` only
  # records a request. Assigning a role already held in the same scope is a
  # no-op. `destroy` is deliberately undeclared: revoking stays a human act in
  # the admin UI, and exposing it as a tool without a declaration fails
  # compilation.
  effects do
    action :read,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :assign,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :administrator,
      intent: :execute

    action :assign_governed,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :administrator,
      intent: :execute

    action :request_assignment,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :propose
  end

  code_interface do
    define :assign
    define :request_assignment, args: [:user_id, :role_id]
    define :read
    define :destroy
  end
end

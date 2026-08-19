defmodule AshEnterprise.Security do
  @moduledoc """
  Authorization as data: roles, privileges, grants and shares.

  The whole model is argued in `docs/manifesto/03-authorization-is-data.md`. In
  short, a principal may act on a record if **any** of three paths grants it, and
  the paths never subtract:

    1. **Role grant** — `(role, privilege, depth)` in `RolePrivilege`, unioned over
       direct roles (`UserRole`) and roles inherited through owner-team membership
       (`TeamRole` ⋈ `TeamMembership`).
    2. **Share** — an explicit `AccessGrant` row for the actor or one of their teams.
    3. **Hierarchy** — manager and position chains (Phase 6).

  Grants are strictly additive. There are no deny rules, which is what makes the
  model order-independent and comprehensible one grant at a time — and is why
  `forbid_if` is banned for row access throughout this codebase.

  ## Not exposed over the public APIs

  Deliberately no `AshJsonApi` or `AshGraphql` here. A filterable public API over
  the authorization tables is a map of the security model, and it answers
  questions ("which roles grant write on payroll?") that are useful mainly to an
  attacker. Administration happens through the admin UI and the MCP tools, both of
  which run through these same resources' policies.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain, AshAi]

  admin do
    show? true
  end

  # Actions exposed to LLM agents over MCP.
  #
  # These are NOT a parallel code path. A tool is a declaration that an existing
  # action may be invoked by a model; the call runs through the same action, the
  # same validations and the same policies as the admin UI. If the requesting
  # user cannot assign roles in the UI, the model cannot assign roles on their
  # behalf, and nobody had to write an agent-specific rule to make that true.
  # See docs/manifesto/05-agents-are-users.md.
  #
  # Note what is absent: no destroy tools. Policies bound what an actor *may* do;
  # they do not bound what is sensible for a probabilistic caller to attempt
  # unsupervised. Revoking a role is deliberately a human action in the admin UI.
  tools do
    tool :list_roles, AshEnterprise.Security.Role, :read do
      description "List the security roles defined in this tenant."
    end

    tool :list_privileges, AshEnterprise.Security.Privilege, :read do
      description "List the privileges that roles can grant, with the depths each supports."
    end

    tool :list_role_assignments, AshEnterprise.Security.UserRole, :read do
      description "List which users hold which roles, and in which business unit scope."
    end

    tool :assign_role, AshEnterprise.Security.UserRole, :assign do
      description """
      Assign a security role to a user, scoped to a business unit.

      Idempotent: assigning a role the user already holds in the same scope is a
      no-op rather than an error. If no scoping business unit is given, the
      user's own is used.
      """
    end
  end

  resources do
    # The catalogue: what can be permitted at all.
    resource AshEnterprise.Security.Privilege

    # The grants: what is permitted, to whom, how far.
    resource AshEnterprise.Security.Role
    resource AshEnterprise.Security.RolePrivilege
    resource AshEnterprise.Security.UserRole
    resource AshEnterprise.Security.TeamRole

    # The exception path: per-record sharing.
    resource AshEnterprise.Security.AccessGrant
    resource AshEnterprise.Security.AccessRequest
  end
end

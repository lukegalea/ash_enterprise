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
    extensions: [AshAdmin.Domain]

  admin do
    show? true
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
  end
end

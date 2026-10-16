defmodule AshEnterprise.Mdm.Egress do
  @moduledoc """
  The MDM egress departure (MDM-6; ADR 0054, addendum of 2026-10-16): the
  tenant's active `:egress` mapping turns this tenant's golden records into
  customer-shaped rows, after the zone disclosure gate. The run is
  `AshEnterprise.Mdm.Export`.

  ## Why a resource of its own

  The golden records are `AshEnterprise.Canonical.Person` rows, and Person is
  owner-only (`AshEnterprise.Security.Privilege.owner_only?/1`): no role
  reaches another user's person rows, because those rows also carry one
  person's mail and Slack correspondents. A generic action on Person is
  authorized by `RoleGrant` only at `:global`, which Person can no longer be
  granted, so an export declared there could be run by nobody.

  Widening Person would undo the mail privacy. Instead the departure is its
  own privilege: `read` on this resource (`prvReadEgress`), derived into the
  catalogue like every other privilege, grantable at `:global` only (the
  resource has no rows and no owner), held by whoever the tenant makes a
  steward. The policy is the platform's inherited grant union, unchanged;
  `RoleGrant` answers from the precomputed `ActorContext` and nothing here
  queries.

  ## What passing the policy authorizes, and nothing more

  Holding the grant authorizes one read, made inside the run without a
  second policy evaluation: **the golden persons of the actor's own tenant**
  (Person's `:goldens` read — no merged loser, nothing no SourceIdentity
  points at), **selecting only the public attributes the active egress
  mapping names**. It is not a Person read grant: the actor still reads
  Person rows through Person's own policies, owner-only, and this action
  returns mapping-shaped rows, never records. It is therefore not a second
  security model; it is one more `(resource, verb)` row in the same one, whose
  reach is fixed in code and reviewed here.

  Tenant: the resource is untenanted (it has no rows to scope), and a grant is
  a row in the tenant that holds it, so the run exports the actor's own
  tenant and refuses any other. That is tenant isolation — the same property
  multitenancy gives every tenanted read — not a deny rule in the grant union.

  The zone disclosure gate (ADR 0042: leaving the zone is a disclosure) still
  runs on every golden, on the residency recorded at land, whoever asks.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check (as on Integration.Gmail).
  resource do
    require_primary_key? false
  end

  actions do
    action :export, {:array, :map} do
      description """
      Export this tenant's golden records through the active `:egress`
      mapping, after the zone disclosure gate (ADR 0054). One inadmissible or
      untagged golden refuses the export whole.
      """

      argument :zone, :string do
        allow_nil? false
        description "The destination zone's id, as declared in the zone declarations."
      end

      run AshEnterprise.Mdm.Export
    end
  end

  code_interface do
    define :export, args: [:zone]
  end
end

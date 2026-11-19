defmodule AshEnterprise.Exports.Export do
  @moduledoc """
  The export privilege: `read` on this resource (`prvReadExport`), derived into the
  catalogue like every other privilege and grantable at `:global` only (the
  resource has no rows and no owner). The tenant's Administrator role picks it up
  with every other privilege (`AshEnterprise.Platform.Seeder`); no other seeded
  role holds it. The policy is the platform's inherited grant union, unchanged:
  `RoleGrant` answers a generic action from the precomputed `ActorContext`, and
  only a `:global` grant passes it. Nothing here queries.

  ## What passing the policy authorizes, and nothing more

  `:open` answers which resource a type names (`AshEnterprise.Exports.Csv.resource_for/1`),
  or `nil` for a type that is not exportable. It reads no rows. The export itself
  is then an ordinary read of that resource as the same actor, in the actor's
  tenant: the resource's own row policies decide which rows are written and its
  field policies which cells are filled. Holding this grant widens no read; it is
  the extra key a person needs to take rows out in bulk, on top of the grants
  that let them read those rows at all.

  Unlike `AshEnterprise.Mdm.Egress` and `AshEnterprise.Audit.Package`, which read
  inside their run without a second policy evaluation, nothing here reads past a
  policy, which is why the action can stay this small.

  ## A person's act

  `:open` is `human_only` (ADR 0059): a system actor, the engines and an automation
  principal acting for a person cannot open an export, whatever grants they carry.
  Taking a tenant's data out in bulk is something a person does with their own key.

  Exports are recorded as telemetry (`[:ash_enterprise, :exports, :csv]`: the type,
  the row count and the duration, never a value), not as rows.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Exports,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    human_only: [:open]

  # Generic actions only and no rows, but the platform's system attributes are still
  # fields, which trips Ash's primary-key check (as on `AshEnterprise.Mdm.Egress`).
  resource do
    require_primary_key? false
  end

  actions do
    action :open, :atom do
      description """
      The resource an export of `type` reads, or nil when `type` is not exportable.
      Passing the policy is the export privilege; the rows are read afterwards as
      the same actor, through that resource's own policies.
      """

      allow_nil? true

      argument :type, :string do
        allow_nil? false

        description ~s(The exported collection's name, as its JSON:API route spells it, e.g. "teams".)
      end

      run AshEnterprise.Exports.Open
    end
  end
end

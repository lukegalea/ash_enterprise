defmodule AshEnterprise.Platform.SystemAttributes do
  @moduledoc """
  Adds the CDM/Dataverse cross-cutting system attributes to a resource.

  This is the mechanism behind [thesis 4](`e:ash_enterprise:04-batteries-are-inherited.md`):
  ownership, provenance, lifecycle, concurrency and tenancy are declared once
  here and inherited by every resource, rather than re-typed per resource and
  forgotten on the eleventh one.

  ## Why an extension rather than a `use` macro that injects DSL blocks

  Injecting `attributes do ... end` from a macro puts the shared columns in a
  second DSL block whose merge behaviour we would be relying on implicitly. A
  Spark transformer adds entities to the already-built DSL state, which is what
  `ash_archival` and friends do, and it composes predictably with whatever the
  resource declares itself. It also means the attributes are *introspectable* —
  `clarity` and `ash_diagram` see them like any other.

  Attributes are added with `add_new_*` semantics: a resource that declares its
  own `owner_id` (say, with a tighter constraint) wins, and nothing is
  clobbered.

  ## The shape is not invented

  These are the CDM's own cross-cutting attribute groups, transcribed:
  `cdsOwnershipInfo`, `cdsCreationModificationDatesAndIds`, `cdsStateAndStatus`,
  `cdsVersionTracking`. Note that the CDM's `CdmEntity` base entity is *empty* —
  it contributes zero attributes — because the CDM expresses "every entity has
  these columns" through attribute-group composition rather than inheritance.
  We use inheritance because that is the idiom Spark gives us. Same invariant,
  different mechanism.

  ## Configuration

      platform do
        ownership :user_owned
        tenant? true
        lifecycle? true
      end

  See `AshEnterprise.Platform.Resource`, which sets sensible defaults so most
  resources never write this block at all.
  """

  @platform %Spark.Dsl.Section{
    name: :platform,
    describe: """
    How this resource participates in the platform's cross-cutting concerns:
    ownership, multitenancy and lifecycle.
    """,
    examples: [
      """
      platform do
        ownership :organization_owned
        lifecycle? false
      end
      """
    ],
    schema: [
      ownership: [
        type: {:one_of, [:user_owned, :business_owned, :organization_owned, :none]},
        default: :user_owned,
        doc: """
        Mirrors Dataverse's OwnershipType, and it decides which authorization
        depths even apply.

        - `:user_owned` — owned by a user or a team. Supports the full
          Basic/Local/Deep/Global ladder. Gets `owner_id`, `owner_type` and the
          denormalized `owning_*` columns. Most business entities.
        - `:business_owned` — owned by a business unit rather than a principal.
          Gets `owning_business_unit_id` only, so Local/Deep still work but
          Basic (owner) does not. This is what Dataverse uses for the security
          furniture itself: `systemuser`, `team`, `businessunit`, `role`.
        - `:organization_owned` — reference and configuration data. Only
          Organization/None are meaningful, so no owner columns are added.
          Dataverse uses it for `organization`, `position`, `languagelocale`,
          `transactioncurrency`, `fieldsecurityprofile`.
        - `:none` — join tables and system tables that are not owned at all:
          `privilege`, `roleprivileges`, `audit`, `principalobjectaccess`.

        In Dataverse this is fixed at table creation and cannot change. Treat it
        the same way here: changing it later is a data migration, not an edit.

        The value for each CDM-derived resource is not guessed — it is scraped
        from the table reference into `priv/cdm/resolved/dataverse_*.json`.
        """
      ],
      tenant?: [
        type: :boolean,
        default: true,
        doc: """
        Add `organization_id` and configure attribute-based multitenancy.

        `organization_id` is CDM-native — every Dataverse table already carries
        it — which is why the tenant column costs us nothing in fidelity.

        Set `false` only for genuinely global tables (time zones, locales).
        """
      ],
      lifecycle?: [
        type: :boolean,
        default: true,
        doc: """
        Add `state_code` and `status_code`.

        These are the Dataverse lifecycle pair: `state_code` is the coarse
        Active/Inactive state and `status_code` is the fine-grained reason, with
        each status belonging to exactly one state. The legal pairs are derived
        from the Dataverse table reference — see `priv/cdm/tools/dataverse_docs.py`
        — and are what an `AshStateMachine` block is generated from.
        """
      ],
      cdm_entity: [
        type: :string,
        required: false,
        doc: """
        The CDM or Dataverse entity this resource was derived from, e.g. `"Team"`.

        Provenance only: it lets us trace a resource back to
        `priv/cdm/resolved/` and re-check it when the corpus is re-resolved.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@platform],
    transformers: [AshEnterprise.Platform.Transformers.AddSystemAttributes]
end

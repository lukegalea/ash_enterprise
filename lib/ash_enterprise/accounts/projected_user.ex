defmodule AshEnterprise.Accounts.ProjectedUser do
  @moduledoc """
  A user row **this application owns**, projected from the legacy estate.

  `AshEnterprise.Legacy.User` reads a compatibility view over `legacy.users`: the shape is
  modern, the storage is not. This is the other half — a real table, created by
  `mix ash.codegen`, with real columns and real indexes — kept current by projecting every
  legacy write through an ordinary Ash action.

  So there are now two surfaces over the same people, and the difference between them is the
  point:

  | | `Legacy.User` | `ProjectedUser` |
  |---|---|---|
  | Storage | a view over `legacy.users` | a table this application owns |
  | Writes | none — `phase :read_from_legacy` | ordinary Ash creates and updates |
  | Audited | no, and could not be | yes, like anything else here |
  | Live because | a synthesized notification | `Ash.Notifier.PubSub`, unremarkably |

  The row keeps the **same `id`** the compatibility view derives — the UUIDv5 of the legacy
  integer key — rather than generating a fresh one. That is what makes the two surfaces
  describable as showing the same row, and it costs nothing: the derivation is deterministic
  in both SQL and Elixir, which is why it was chosen in the first place
  ([ADR 0008](../../../docs/adr/0008-typed-invertible-legacy-mappings.md), §4.1 of the
  strangler plan).

  ## Why this is not `Accounts.User`

  `Accounts.User` is the authentication resource. `hashed_password` is `allow_nil? false`, and
  §4.6 of `docs/plans/ash-strangler-in-reference-app.md` excludes password material from the
  migration deliberately — the legacy hashes are a different scheme and re-hashing is
  impossible without the plaintext. Projecting into it would mean writing a fabricated hash
  into a security-relevant column, which is a worse thing to do than having two resources.

  `Accounts.User` is where this lands at step 8, when the legacy tables are dropped and the
  strangler DSL disappears. Until then the honest name for this is a projection.

  ## Audit becomes possible here, and that is the interesting part

  `Legacy.User` sets `audit?: false`, and the reason is written in that module: the writes worth
  auditing are the legacy application's, and they are invisible to any notifier Ash could
  install. Claiming a trail over them would be worse than not claiming one.

  A projection changes that. The write into *this* table is an Ash action, so it produces an
  ordinary audit event — attributed to `SystemActor.projection/0`, because the actor who really
  made the change was a Rails process this application cannot see, and naming a person would be
  a lie. What the trail says is "the projector wrote this, sourced from legacy id 7", which is
  exactly what happened.

  ## `email` carries no identity, still

  Two seeded legacy rows differ only by case (`Dana@corp.example` and `dana@corp.example`), and
  a `:ci_string` identity considers them one person. Asserting the identity here would make the
  projection silently drop somebody — a *new* loss, introduced by the new model, on top of the
  data-quality defect it inherited. That is strictly worse than carrying both rows and showing
  the collision.

  The identity arrives at the expand step, behind a migration that fails loudly if the data
  still violates it. Until then `legacy_id` is the unique key, because it is the one the source
  actually guarantees. A test asserts both Dana rows project, since "the projection does not
  lose people" is the property that matters and it is not self-evident.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :business_owned,
    cdm_entity: "Contact",
    audit?: true,
    api_type: :both,
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "projected_users"
    repo AshEnterprise.Repo
  end

  # What makes the surface at /app/directory live. Unlike the legacy read model, none of this
  # is synthesized: the projector runs a real Ash action, so `Ash.Notifier.PubSub` fires the
  # way it does for every other resource here, and `publish` on a named action would work too.
  # `publish_all` is kept only so the topics match the legacy surface's and one helper can read
  # both.
  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "projected_users"

    publish_all :create, ["created"]
    publish_all :update, ["updated"]
    publish_all :destroy, ["destroyed"]
  end

  attributes do
    # Supplied, not generated. See the moduledoc: this is the compatibility view's derived
    # uuid, so the same person has the same id whichever surface you are looking at.
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      writable? true
      public? true
      description "The UUIDv5 the compatibility view derives from the legacy integer key."
    end

    attribute :legacy_id, :integer do
      allow_nil? false
      public? true

      description "`legacy.users.id`. The upsert key, because it is the one the source guarantees."
    end

    attribute :login, :string, public?: true

    attribute :email, :ci_string do
      public? true
      description "No identity at this phase -- see the moduledoc."
    end

    attribute :full_name, :string do
      public? true

      description """
      Projected, not decomposed. The legacy schema has `first_name` and `last_name`; this
      application has one name field, and going back the other way is what makes a true cutover
      hard ('de la Cruz' splits wrong). Carried as one string because that is what is known.
      """
    end

    attribute :legacy_state, :string do
      public? true

      description "The legacy state machine's value, verbatim. Five values, against this platform's two."
    end

    attribute :projected_at, :utc_datetime_usec do
      allow_nil? false
      public? true

      description "When the projector last wrote this row. The lag between legacy and here, made visible."
    end
  end

  identities do
    # `all_tenants? false` by default, and the multitenancy attribute is prepended to the index
    # by the migration generator -- so this is `(organization_id, legacy_id)`. Correct: the
    # legacy estate is one tenant, and a second legacy estate would number from 1 again.
    identity :from_legacy, [:legacy_id]
  end

  actions do
    defaults [:read]
    default_accept []

    create :project do
      description "Upsert one legacy row into this table. Called only by AshEnterprise.Legacy.Projection."
      primary? true
      upsert? true
      upsert_identity :from_legacy

      accept [:id, :legacy_id, :login, :email, :full_name, :legacy_state]

      change set_attribute(:projected_at, &DateTime.utc_now/0)

      # The legacy estate's tenant and root business unit. Constants at this phase for the same
      # reason they are constants in the mapping: `company_id` was never a security boundary,
      # and making it one silently is the mistake §4.3 of the plan exists to prevent.
      change set_attribute(:organization_id, AshEnterprise.Legacy.Estate.organization_id())

      change set_attribute(
               :owning_business_unit_id,
               AshEnterprise.Legacy.Estate.business_unit_id()
             )
    end

    update :reproject do
      description "Update an already-projected row. Separate from :project so the upsert has one shape."
      require_atomic? false
      accept [:login, :email, :full_name, :legacy_state]
      change set_attribute(:projected_at, &DateTime.utc_now/0)
    end
  end

  code_interface do
    define :project, action: :project
    define :reproject, action: :reproject
    define :by_legacy_id, action: :read, get_by: [:legacy_id], get?: true
  end
end

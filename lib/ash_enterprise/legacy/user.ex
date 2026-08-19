defmodule AshEnterprise.Legacy.User do
  @moduledoc """
  The read model over `legacy.users` — a platform resource whose data layer is a
  compatibility view rather than a table this application owns.

  This is step 2 of `docs/plans/ash-strangler-in-reference-app.md`: the legacy
  estate, declared once as a typed mapping, and thereafter indistinguishable
  from any other resource here. It gets the same policies, the same tenancy, the
  same admin UI and the same A2UI surface as a resource we designed, because
  those are consequences of `AshEnterprise.Platform.Resource` rather than things
  a resource opts into.

  ## What the mapping had to resolve

  Every conflict below is a real property of the legacy schema, and each one is
  argued at length in the plan. Read them as the honest cost of the demo rather
  than as decoration:

    * **`id` is `serial`, and every platform foreign key is `:uuid`** (§4.1). The
      view computes a deterministic UUIDv5 from the legacy key, so the same value
      is derivable in SQL and in Elixir without a lookup table and without
      writing anything to a schema we do not own. `legacy_id` carries the integer
      across, because the derivation runs one way only.

    * **There is no tenant column** (§4.2). The legacy application was
      single-tenant, so `organization_id` is a constant: one `Organization` row
      representing the whole legacy estate. That multitenancy can be *added* to
      data that never had it is a property of expressing tenancy as a column.

    * **`company_id` was never a security boundary** (§4.3). It filtered reports.
      Mapping it to `owning_business_unit_id` would make it one silently, so at
      this phase every legacy row maps to the root business unit and depth
      semantics degenerate: `:local`, `:deep` and `:global` all reach everything.
      **The authorization model is present but not yet load-bearing.** Projecting
      `legacy.companies` into `BusinessUnit` is step 5, and it *narrows* access
      for everyone the moment it lands.

    * **`deleted_at` is `acts_as_paranoid`**, which is soft delete under another
      name, so it maps straight onto the attribute `AshArchival` already adds.
      The legacy application and this one agree about what deleted means without
      either being told about the other.

    * **`state` carries five values and `lifecycle_status` carries two.** That
      collapse is lossy and therefore not invertible, which is why it is declared
      `read_only?` with a reason rather than as a `decode`. Writing `:inactive`
      back has no single correct answer — `passive`, `pending`, `suspended` and
      `deleted` all produce it. See §4.7 for the same shape in the privilege
      model.

  ## Phase

  `:read_from_legacy`. Nothing here writes, and `migrate? false` says Ash owns
  the view and not the table underneath. The DDL comes from
  `mix ash_strangler.gen.migration`, never from `mix ash.codegen`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Legacy,
    ownership: :business_owned,
    cdm_entity: "Contact",
    # No writes exist to audit at this phase, and the writes worth worrying
    # about are the legacy application's -- which are invisible to any notifier
    # Ash could install. Claiming an audit trail over a view we cannot see the
    # writes to would be worse than not claiming one. See plan §4.8.
    audit?: false,
    extra_extensions: [AshStrangler.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    # The VIEW, in schema `strangler`. Not `legacy.users`.
    table "users"
    schema "strangler"
    repo AshEnterprise.Repo
    # Ash owns the view, not the legacy table.
    migrate? false
  end

  actions do
    defaults [:read]
    default_accept []
  end

  # Broadcasts a legacy write onto Phoenix.PubSub, which is what makes the A2UI
  # surface at /app/legacy-users live. The chain is worth stating end to end
  # because every link is opt-in and a break anywhere is silent:
  #
  #   legacy INSERT -> AFTER trigger (notify? true, above)
  #                 -> pg_notify, on commit only
  #                 -> AshStrangler.Listener re-reads through Ash
  #                 -> Ash.Notifier.Notification
  #                 -> here
  #                 -> "legacy_users:created" on AshEnterprise.PubSub
  #                 -> AshEnterpriseWeb.A2uiLive.LegacyUsers refreshes
  #
  # `publish_all` and not `publish`: a legacy write is not an Ash action, so the
  # notification the listener synthesizes carries an action named `:legacy_write`
  # that this resource does not declare. `publish_all` matches on the action's
  # TYPE and therefore fires; `publish :some_action` matches on its NAME and
  # would silently never match. That is a property of strangled read models in
  # general -- see AshStrangler's usage rules, #30.
  #
  # Through the endpoint rather than AshEnterprise.PubSub directly, so the
  # message arrives as a %Phoenix.Socket.Broadcast{} on the pubsub server the
  # endpoint is configured with -- which is the server a LiveView subscribes to.
  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "legacy_users"

    publish_all :create, ["created"]
    publish_all :update, ["updated"]
    publish_all :destroy, ["destroyed"]
  end

  attributes do
    # No default, and no `uuid_primary_key` -- the view computes this value, and
    # the extension marks it `generated?` so Ash does not demand it on write.
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true

    attribute :legacy_id, :integer do
      public? true
      description "The `legacy.users.id` this row came from. The uuid derivation runs one way."
    end

    attribute :login, :string, public?: true

    attribute :email, :ci_string do
      public? true

      description """
      Deliberately carries NO identity at this phase. `index_users_on_email` is
      neither unique nor case-insensitive, and the seed data contains a
      collision -- a data-quality defect the new model surfaces and the old one
      tolerated. The identity arrives at the expand step, with a migration that
      fails loudly if the data still violates it.
      """
    end

    attribute :full_name, :string, public?: true
    attribute :legacy_state, :string, public?: true
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.Users do
      notify? true

      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})

      map :legacy_id, from: :id
      map :login, from: :login
      map :email, from: :email

      # SQL's `||` propagates NULL, so every operand is null-defaulted: one
      # absent last_name would otherwise blank the whole value.
      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because:
          "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it. Write first_name and last_name in the legacy application."

      map :legacy_state,
        from: expr(type(state, :string)),
        read_only?: true,
        because:
          "The legacy state machine is the old application's, not ours. Change it there; `lifecycle_status` is what this application reasons about."

      # Five legacy values collapse onto two lifecycle statuses, so the reverse
      # is ambiguous by construction.
      map :lifecycle_status,
        from:
          expr(
            if(state == :active,
              do: type("active", :string),
              else: type("inactive", :string)
            )
          ),
        read_only?: true,
        because:
          "Lossy: passive, pending, suspended and deleted all collapse onto :inactive, so there is no single legacy value to write back. Set `legacy.users.state` directly."

      # acts_as_paranoid IS soft delete. Naive timestamps, so the zone has to be
      # stated -- it is a fact about the old application, and nothing in the
      # database records it.
      map :archived_at, from: :deleted_at, zone: "UTC"
      map :created_on, from: :created_at, zone: "UTC"
      map :modified_on, from: :updated_at, zone: "UTC"

      # The legacy estate is one tenant, and every legacy row belongs to it.
      constant(
        :organization_id,
        expr(type("00000000-0000-0000-0000-0000000000fe", :uuid))
      )

      # The root business unit. company_id was never a security boundary; it
      # becomes one at step 5, not here.
      constant(
        :owning_business_unit_id,
        expr(type("00000000-0000-0000-0000-0000000000fd", :uuid))
      )

      # Optimistic locking has nothing to lock against while nothing writes.
      constant(:version_number, expr(1))

      unmapped(
        [
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id
        ],
        as: :null,
        because:
          "The legacy application recorded no actor on any write. Inventing one would put a false name in the provenance columns, which is worse than an absent one."
      )

      unmapped([:overridden_created_on, :import_sequence_number],
        as: :null,
        because:
          "Nothing was imported: these rows are read in place, through a view. Both columns become meaningful at the backfill step."
      )
    end
  end
end

defmodule AshEnterprise.Assistant.PinnedApp do
  @moduledoc """
  A surface the person composed in the agent chat and pinned: a personal app,
  listed under "My apps" on their launcher (`/app`) and opened at
  `/app/mine/<id>`.

  ## What is stored

  The composed surface's spec, in `AshA2ui.Dynamic`'s canonical serialized
  form (`AshA2ui.Dynamic.serialize/1`) — never A2UI messages, never rows. The
  spec is structural: a resource name from the host allowlist, field and read
  action names, a board's lane values. The composer
  (`AshEnterprise.Assistant.Composer`) writes no free text into it, and the
  `title` is derived from the spec, not written by the model, so nothing here
  quotes mail, Slack or a name and nothing needs sealing.

  ## Verified on every load

  A stored spec is a claim about resources that may have changed since it was
  pinned. Opening one deserializes it through `AshA2ui.Dynamic.deserialize/2`
  against the composer's allowlist, which re-runs every verifier; a spec that
  no longer resolves is shown as its errors, never rendered from the stored
  text. The rows are read as the person, under their policies, each time.

  ## Owner-only

  User-owned and owner-only (`AshEnterprise.Security.Privilege.owner_only?/1`).
  Pinning and reading one's own are self-service (ADR 0052); unpinning is the
  generic `:unpin`, which finds the app through `:mine` as the actor before it
  removes it, so it reaches only the actor's own pins. Nobody else's launcher
  shows it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:pin, :read, :mine, :unpin]

  postgres do
    table "assistant_pinned_apps"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:owner_id, :inserted_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 120
      description "A structural title derived from the spec (\"Tasks · board\"), not model text."
    end

    attribute :display, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:table, :calendar, :board]
      description "How the surface shows its records."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints max_length: 32
      description "What it shows: the composer's name for the resource (events, tasks, ...)."
    end

    attribute :spec, :string do
      allow_nil? false
      public? true
      constraints max_length: 16_000
      description "The composed spec, serialized canonically (AshA2ui.Dynamic.serialize/1)."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    read :mine do
      description "The actor's own pinned apps, oldest first (the launcher's order)."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [inserted_at: :asc])
    end

    create :pin do
      description "Pin a composed surface for the actor."

      accept [:title, :display, :source, :spec]

      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
    end

    destroy :remove do
      description "Remove a pin. Reached by `:unpin`, which scopes it to the actor's own."
    end

    action :unpin do
      description "Unpin one of the actor's own apps: found through `:mine`, then removed."

      argument :app_id, :uuid do
        allow_nil? false
      end

      run AshEnterprise.Assistant.Actions.Unpin
    end
  end

  code_interface do
    define :pin
    define :mine
    define :unpin, args: [:app_id]
    define :get, action: :read, get_by: [:id]
  end
end

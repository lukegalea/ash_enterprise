defmodule AshEnterprise.Quality.Suite do
  @moduledoc """
  A suite of evaluation cases for an agent (ADR 0058), in table `quality_suites`: a key
  and a version, `draft → published → retired`.

    * **Cases** are `AshEnterprise.Quality.Case` maps in Inspect's `Sample` shape, each
      with a stable `id`, the fixtures its run is answered with, a split, tags and
      deterministic assertions (`AshEnterprise.Quality.Assertions`). They are checked
      when written (`AshEnterprise.Quality.Validations.Cases`): unique ids, and every
      assertion has what it needs to be measured.
    * **Publishing freezes them**: `add_case` writes only to a draft, and `publish`
      records `content_hash`, the SHA-256 of the RFC 8785 canonical JSON of the cases,
      thresholds and primary metric. A changed suite is a new version (`create_draft`
      numbers it after the key's latest).
    * **Thresholds** (`%{"pass_rate" => 0.9}`, say) and the primary metric are the
      suite's own; the release gate reads them.
    * **Provenance**: where the cases came from, their usage terms, consent basis and
      permitted use.

  Organization-owned and audited: suites are configuration, read and written through
  role grants (reading is the `quality.read` privilege of ADR 0058, writing and
  publishing `quality.publish`). They live in the tenant evaluations run in.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Quality,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshStateMachine]

  alias AshEnterprise.Quality.{Case, Changes, Validations}

  postgres do
    table "quality_suites"
    repo AshEnterprise.Repo
  end

  state_machine do
    state_attribute :status
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :publish, from: :draft, to: :published
      transition :retire, from: :published, to: :retired
    end
  end

  actions do
    defaults [:read]

    read :latest_published do
      description "The latest published version of the suite keyed `key`."
      get? true

      argument :key, :string, allow_nil?: false

      filter expr(key == ^arg(:key) and status == :published)
      prepare build(sort: [version: :desc], limit: 1)
    end

    create :create_draft do
      description "A new draft of the suite keyed `key`, numbered after its latest version."
      accept [:key, :cases, :thresholds, :primary_metric, :provenance]

      change Changes.NextVersion
      validate Validations.Cases
    end

    update :add_case do
      description "Add a case to a draft."
      accept []
      require_atomic? false

      argument :case, Case, allow_nil?: false

      validate attribute_equals(:status, :draft), message: "only a draft takes new cases"
      change Changes.AddCase
      validate Validations.Cases
    end

    update :publish do
      description "Publish a draft, freezing its cases under their content hash."
      accept []
      require_atomic? false

      change transition_state(:published)
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change Changes.HashContent
    end

    update :retire do
      description "Retire a published version."
      accept []
      require_atomic? false

      change transition_state(:retired)
      change set_attribute(:retired_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :cases, {:array, Case} do
      allow_nil? false
      public? true
      default []
    end

    attribute :thresholds, :map do
      allow_nil? false
      public? true
      default %{}
      description ~s(The suite's floors, by metric: `%{"pass_rate" => 0.9}`.)
    end

    attribute :primary_metric, :string do
      allow_nil? false
      public? true
      default "pass_rate"
      constraints max_length: 64
    end

    attribute :provenance, :map do
      allow_nil? false
      public? true
      default %{}
      description "Where the cases came from: source, usage terms, consent basis, permitted use."
    end

    attribute :content_hash, :string do
      public? true

      description "SHA-256 of the canonical JSON of the cases, thresholds and primary metric, set at publish."
    end

    attribute :published_at, :utc_datetime_usec, public?: true
    attribute :retired_at, :utc_datetime_usec, public?: true
  end

  identities do
    identity :unique_version, [:key, :version]
  end
end

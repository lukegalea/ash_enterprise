defmodule AshEnterprise.Planning.Fragment.ModelVersion do
  @moduledoc """
  The pure shape of one immutable planning model version: a reviewed MiniZinc model, its
  checker, and the independent Elixir validator that must agree with it, identified by
  content hash.

  Attributes, actions, validations and identities only. Tenancy, ownership, audit, policies
  and the `postgres` block are the host's: this module is written to move into the
  `ash_planning` package unchanged apart from its name.

  ## Lifecycle

  `draft → published → retired`. Only a draft changes (`revise`); `publish` freezes the
  row and `retire` takes it out of use. There is no destroy: a Run pins a model version by
  id, so a version is retired, never removed. Whether a published version's hard
  requirements are within the backend's `capabilities` is the publication verifier's job in
  the package; this fragment only constrains the key vocabulary.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  @capabilities [
    :integer_variables,
    :optional_intervals,
    :cumulative,
    :no_overlap,
    :time_windows,
    :precedence,
    :objective_bound,
    :warm_start,
    :routing
  ]

  @doc "The nine v1 capability keys."
  @spec capabilities() :: [atom()]
  def capabilities, do: @capabilities

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
      description "The model's name, e.g. `\"personal_week\"`. Stable across versions."
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
      description "Positive version number; `(key, version)` is unique."
    end

    attribute :model_sha256, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
      description "Lowercase hex SHA-256 of the `.mzn` model document."
    end

    attribute :checker_sha256, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
      description "Lowercase hex SHA-256 of the `.mzc.mzn` solution checker."
    end

    attribute :validator_module, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255

      description """
      The independent Elixir validator's module name, as a string. It is resolved with
      `Module.safe_concat/1` where it is used, never by creating an atom from this value.
      """
    end

    attribute :validator_sha256, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
      description "Lowercase hex SHA-256 of the validator's source."
    end

    attribute :backend_profile, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      The backend identity and declared limits the model is reviewed against (solver,
      time/memory ceilings). Structural values only.
      """
    end

    attribute :capabilities, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: @capabilities]

      description "The hard requirements the model makes of a backend, from the nine v1 keys."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :published, :retired]
      description "`draft → published → retired`. Immutable once published."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :draft do
      description "Register a model version as a draft."

      accept [
        :key,
        :version,
        :model_sha256,
        :checker_sha256,
        :validator_module,
        :validator_sha256,
        :backend_profile,
        :capabilities
      ]
    end

    update :revise do
      description "Change a draft. A published or retired version never changes."

      accept [
        :model_sha256,
        :checker_sha256,
        :validator_module,
        :validator_sha256,
        :backend_profile,
        :capabilities
      ]

      require_atomic? false

      validate attribute_equals(:status, :draft), message: "only a draft can be revised"
    end

    update :publish do
      description "Freeze a draft: from here its hashes, validator and capabilities never change."
      accept []
      require_atomic? false

      validate attribute_equals(:status, :draft), message: "only a draft can be published"
      change set_attribute(:status, :published)
    end

    update :retire do
      description "Take a published version out of use. Runs that pinned it keep it."
      accept []
      require_atomic? false

      validate attribute_equals(:status, :published),
        message: "only a published version can be retired"

      change set_attribute(:status, :retired)
    end
  end

  identities do
    identity :unique_key_version, [:key, :version]
  end
end

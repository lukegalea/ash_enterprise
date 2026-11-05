defmodule AshEnterprise.Planning.Fragment.CheckResult do
  @moduledoc """
  The pure shape of one check of one candidate: what the MiniZinc solution checker said and,
  separately, what the independent Elixir validator said.

  Create-only. There is no update and no destroy: a re-check is a new row. Clear columns
  carry statuses and reason codes; the violations themselves are in `violation_details`,
  declared `sensitive?` for the host to seal, and `checker_output_digest` lets a replay
  confirm the checker's raw output without keeping it.

  Attributes, actions and validations only; tenancy, ownership, sealing and policies are the
  host's. Written to move into the `ash_planning` package unchanged apart from its name.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    uuid_primary_key :id

    attribute :candidate_id, :uuid do
      allow_nil? false
      public? true
      description "The candidate that was checked."
    end

    attribute :checker_status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:correct, :incorrect, :checker_failed]
      description "The MiniZinc solution checker's verdict."
    end

    attribute :checker_reason, :string do
      public? true
      constraints max_length: 64
      description "A reason code, never free text."
    end

    attribute :validator_status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:correct, :incorrect, :validator_failed]
      description "The independent Elixir validator's verdict."
    end

    attribute :validator_reason, :string do
      public? true
      constraints max_length: 64
      description "A reason code, never free text."
    end

    attribute :checker_output_digest, :string do
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
      description "Lowercase hex SHA-256 of the checker's raw output."
    end

    attribute :violation_details, :binary do
      public? false
      sensitive? true
      description "What was violated, in detail. Sealed by the host."
    end

    create_timestamp :inserted_at
  end

  actions do
    defaults [:read]

    create :record do
      description "Record one check of one candidate."

      accept [
        :candidate_id,
        :checker_status,
        :checker_reason,
        :validator_status,
        :validator_reason,
        :checker_output_digest,
        :violation_details
      ]
    end
  end
end

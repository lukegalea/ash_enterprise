defmodule AshEnterprise.Quality.CaseResult do
  @moduledoc """
  What one case of a suite run scored, at one epoch (ADR 0058), in table
  `quality_case_results`: written once by the suite run's `finish`, never changed.

    * `status`: `:failed` when any assertion failed; else `:errored` when the case's run
      did not complete; else `:unmeasured` when no assertion could be measured; else
      `:passed`. (`:skipped` is for a case a run chose not to run.)
    * `assertion_results`: each assertion's result, with whether it is hard
      (`AshEnterprise.Quality.Assertions.evaluate/2`).
    * `prohibited_effect_hit`: whether the run asked for an effect the case prohibits.
    * `scores`: model-graded scores with their judgment ledger ids, which report and do
      not gate; empty until a suite declares judged scorers.
    * `run_id`: the case's agent run.

  Owned by the suite run's owner (`AshEnterprise.Quality.Changes.FromSuiteRun`), so the
  grants that read a suite run read its results. Not audited (`audit?: false`): the
  results are an append-only ledger, as an agent run's steps are; the suite run's
  `finish` that writes them is audited.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Quality,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    lineage?: false,
    machinery_only: [:record]

  postgres do
    table "quality_case_results"
    repo AshEnterprise.Repo

    references do
      reference :suite_run, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Record what one case of a suite run scored."

      accept [
        :suite_run_id,
        :case_id,
        :epoch,
        :status,
        :assertion_results,
        :scores,
        :prohibited_effect_hit,
        :run_id
      ]

      change AshEnterprise.Quality.Changes.FromSuiteRun
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :case_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :epoch, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:passed, :failed, :errored, :skipped, :unmeasured]
    end

    attribute :assertion_results, {:array, :map} do
      allow_nil? false
      public? true
      default []
    end

    attribute :scores, {:array, :map} do
      allow_nil? false
      public? true
      default []
    end

    attribute :prohibited_effect_hit, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :run_id, :uuid do
      public? true
      description "The case's agent run."
    end
  end

  relationships do
    belongs_to :suite_run, AshEnterprise.Quality.SuiteRun do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_case_epoch, [:suite_run_id, :case_id, :epoch]
  end
end

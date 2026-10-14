defmodule AshEnterprise.Mdm.MappingProposal do
  @moduledoc """
  What the proposer said (MDM-8): the stage and raw output of an AI mapping
  proposal, retained on its own row — the mapping lifecycle overwrites
  `validation_findings` on every validate, and "what the model said" is
  provenance the operator must still be able to read after a person has
  edited and activated the draft.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false

  postgres do
    table "mdm_mapping_proposals"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :mapping_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :stage, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:deterministic_only, :llm, :llm_refused, :llm_invalid]
    end

    attribute :raw, :map do
      public? true
    end

    create_timestamp :inserted_at
  end

  actions do
    read :read do
      primary? true
    end

    create :record do
      accept [:mapping_id, :stage, :raw]
    end

    read :for_mapping do
      get? true
      argument :mapping_id, :uuid, allow_nil?: false
      filter expr(mapping_id == ^arg(:mapping_id))
    end
  end
end

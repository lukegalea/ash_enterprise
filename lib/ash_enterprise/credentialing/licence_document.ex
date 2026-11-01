defmodule AshEnterprise.Credentialing.LicenceDocument do
  @moduledoc """
  One document a credential rests on: the licence certificate the clinician handed in,
  or the issuing body's register extract. Invented, like `Credential`: the CDM has no
  entity for one.

  The document itself is an `AshEvidence.DocumentVersion` (`document_version_id`), and
  its lines are the version's addressed atoms: the evidence store holds the text, this
  row says which credential the document is for and what kind it is.

  ## What an agent does with it

  The licence reader (`AshEnterprise.Credentialing.LicenceReader`) reads a credential's
  documents and records what they say, through two tools here:

    * `read_text` gives the document's lines, numbered. A lookup: it changes nothing,
      reaches nothing outside, and an agent run calls it as an invocation, so a step
      that is repeated (its model timed out, F1) reads the recorded result instead of
      looking again.
    * `record_finding` records one answer to one of the two questions below as a
      judgment (`AshEnterprise.SystemOne.Judgment`, the `ash_judgments` ledger): its
      typed value, its status, and the lines it rests on, as the atoms' ids. The row
      carries the run, step, tool call and invocation that wrote it.

  A finding is an observation, never a fact (`ash_judgments` law 1): nothing here
  changes the credential.

  The two questions are `AshJudgments.Evaluate.Extraction` questions of family
  `:licence_documents`: the licence number a document states, and the date it says the
  licence is valid until. A finding cites atoms of the document it is about and no other
  (the packet's ids, narrowed per call). Their hashes are locked in
  `priv/judgments/lock.json`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    ownership: :user_owned,
    lifecycle?: false,
    extra_extensions: [AshAi, AshJudgments.Registry, AshAgent.Effects]

  postgres do
    table "credentialing_licence_documents"
    repo AshEnterprise.Repo
  end

  @kinds [:certificate, :register_extract]
  @questions [:licence_number, :licence_valid_until]

  @doc "The kinds of document: the certificate and the register extract."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The questions a finding answers."
  @spec questions() :: [atom()]
  def questions, do: @questions

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :document_version_id, :uuid do
      allow_nil? false
      public? true
      description "The document in the evidence store (`AshEvidence.DocumentVersion`)."
    end
  end

  relationships do
    belongs_to :credential, AshEnterprise.Credentialing.Credential do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :one_per_kind, [:credential_id, :kind]
  end

  actions do
    defaults [:read]

    create :file do
      description "File a document for a credential, owned by the person filing it."
      accept [:kind, :title, :document_version_id, :credential_id]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
    end

    action :read_text, :map do
      description """
      The lines of one of a credential's documents, numbered: the certificate or the
      register extract. Cite a line by its number.
      """

      argument :number, :string do
        allow_nil? false
        public? true
        description "The credential's number, as the run was given it."
      end

      argument :kind, :atom do
        allow_nil? false
        public? true
        constraints one_of: @kinds
      end

      run AshEnterprise.Credentialing.Actions.ReadLicenceText
    end

    action :record_finding, :map do
      description """
      Record what one of a credential's documents says in answer to a question, and the
      lines that say it. status is found, not_found or ambiguous; give a value only when
      it is found (a date as YYYY-MM-DD).
      """

      argument :number, :string, allow_nil?: false, public?: true

      argument :kind, :atom do
        allow_nil? false
        public? true
        constraints one_of: @kinds
      end

      argument :question, :atom do
        allow_nil? false
        public? true
        constraints one_of: @questions
      end

      argument :status, :atom do
        allow_nil? false
        public? true
        constraints one_of: [:found, :not_found, :ambiguous]
      end

      argument :value, :string, public?: true

      argument :lines, {:array, :integer} do
        allow_nil? false
        public? true
        default []
        description "The numbers of the lines the answer rests on."
      end

      run AshEnterprise.Credentialing.Actions.RecordLicenceFinding
    end
  end

  effects do
    action :read_text,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :record_finding,
      kind: :edit,
      destructive?: false,
      idempotent?: false,
      open_world?: false,
      intent: :propose
  end

  judgments do
    question :licence_number do
      type AshJudgments.Evaluate.Extraction
      instructions("Extract the licence number the document states.")
      version(1)
      family(:licence_documents)
      profile(:splash_generative)
      constraints(of: :string)
      source_enum_from({AshEvidence.AddressedAtom, :id})
    end

    question :licence_valid_until do
      type AshJudgments.Evaluate.Extraction
      instructions("Extract the date the document says the licence is valid until.")
      version(1)
      family(:licence_documents)
      profile(:splash_generative)
      constraints(of: :date)
      source_enum_from({AshEvidence.AddressedAtom, :id})
    end
  end
end

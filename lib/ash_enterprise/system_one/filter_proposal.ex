defmodule AshEnterprise.SystemOne.FilterProposal do
  @moduledoc """
  An NL-search filter proposal (S1-65; S1-56 §3, ADR 0046/0048): the model
  translates a natural-language search into a candidate Basic CQL2
  document, and what lands here is an EDITABLE PROPOSAL — never a
  execution-ready artefact, never anything that runs by itself.

  The mechanism is the S1-61 question-proposal machinery applied to
  filters (the search IS the filter, S1-56 §3.1):

  1. **Propose.** `propose/1` resolves an in-zone generative profile
     through the ordinary profile machinery (residency guard, region
     rule), calls the SAME transport the question proposals use (the
     structured-output schema rides the wire), and decodes under the
     DERIVED wire schema — Basic CQL2 with property names restricted to
     the declared queryables (`Filter.Queryables`). An undecodable or
     schema-invalid answer becomes a **refused** proposal with the raw
     output retained — never a best-effort parse, and a failed translation
     opens nothing (the builder's empty state is the refused row).
  2. **Edit — a new version, re-validated.** `edit/3` is a person act: the
     (possibly edited) document is re-run through the full decode contract
     and stored as a NEW VERSION (same root, version+1, predecessor
     superseded). A version that fails re-validation is refused and
     nothing is written. The whole chain stays visible; nothing is
     overwritten.
  3. **Approve — the person gate.** `approve` requires a person actor (a
     user row; system actors, automation labels and the `ai` actor all
     fail). ONLY an approved document runs (`Filter.Runner`), and running
     is always an explicit act — there is no path that executes model
     output unedited, and no silent filtering (S1-56 §3.1).

  The proposal never auto-runs and never rides a read path: translation is
  a separate recorded instrument call, the run is a person-approved act,
  and the executed query is audited on `FilterExecution` with the final
  post-edit document and the compiled plan.

  ## Instrument-call record

  As with question proposals, the mechanism records its own instrument
  interaction: the profile, and the wire question hash — the digest of the
  ad-hoc wire question (prompt plus schema, RFC §3.3 discipline for an
  undeclared question). The v0 ledger fragment's `answer_kind` enum does
  not yet admit `extraction` rows, so the proposal row is where the call is
  recorded (the S1-61 posture); the execution row links this digest to what
  ran, making the translation observation and the executed query one
  provenance chain (S1-56 §3.5).

  `nl_text` and `raw_output` are payload class: person-authored search text
  and model output, erasable, never exported. Everything else — digests,
  documents, versions, statuses — is envelope class.
  """

  @type t :: %__MODULE__{}

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false

  alias AshEnterprise.SystemOne.Filter
  alias AshEnterprise.SystemOne.Filter.Document
  alias AshEnterprise.SystemOne.Filter.Queryables
  alias AshEnterprise.SystemOne.QuestionProposal.Transport
  alias AshJudgments.Registry.Canonical

  postgres do
    table "system_one_filter_proposals"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      allow_nil?: false,
      default: :proposed,
      public?: true,
      constraints: [one_of: [:proposed, :refused, :approved, :rejected, :superseded]]

    attribute :source, :string,
      allow_nil?: false,
      default: "search",
      public?: true,
      description:
        "Where the search text came from (the search box, an API surface). Envelope class."

    attribute :nl_text, :string,
      allow_nil?: false,
      public?: false,
      constraints: [trim?: false],
      description:
        "The natural-language search text, byte-faithful. PAYLOAD CLASS: person-authored prose; the digest is computed over these exact bytes."

    attribute :nl_digest, :string,
      allow_nil?: false,
      public?: true,
      description: "Canonical digest of the search text (RFC §4.2). Envelope class."

    attribute :document, :map,
      allow_nil?: true,
      public?: true,
      description:
        "The candidate Basic CQL2 document (JSON-safe, validated). The proposal the person edits and approves. Nil on refusal."

    attribute :refusal_reason, :string,
      public?: true,
      description:
        "Set when status is refused: why the model output was not a decodable document."

    attribute :raw_output, :string,
      allow_nil?: true,
      public?: false,
      constraints: [trim?: false],
      description:
        "The model's raw textual output, byte-faithful, retained for inspection — required on refusal. PAYLOAD CLASS."

    attribute :profile, :string,
      allow_nil?: false,
      public?: true,
      description: "The in-zone instrument that translated the search text."

    attribute :question_id, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The reserved exploratory question id of the mechanism itself (S1-56 §4.2): judgment:v0:<Module>#judgments/exploratory."

    attribute :wire_question_hash, :string,
      allow_nil?: false,
      public?: true,
      description:
        "Digest of the ad-hoc wire question — prompt plus schema (RFC §3.3). The translation observation's digest; executions link back to it."

    attribute :queryables_hash, :string,
      allow_nil?: false,
      public?: true,
      description:
        "Digest of the declared queryables this version validated against. A run re-checks it: a vocabulary change between edit and run is a refusal, never a drift."

    attribute :version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true,
      description:
        "The version within this proposal chain. Edits mint new versions; nothing is overwritten."

    attribute :root_id, :uuid,
      allow_nil?: true,
      public?: true,
      description:
        "The first version's id (nil on the first version itself). Every version of one proposal shares it."

    attribute :supersedes_id, :uuid,
      allow_nil?: true,
      public?: true,
      description: "The previous version this one replaces (a person edit)."

    create_timestamp :proposed_at
  end

  actions do
    defaults [:read]

    create :propose do
      description """
      Records one translation run. Every field is an input — the instrument
      was called before this create, and replay rebuilds the row without
      consulting a model (the ledger's §6.1 discipline, applied here).
      """

      accept [
        :status,
        :source,
        :nl_text,
        :nl_digest,
        :document,
        :refusal_reason,
        :raw_output,
        :profile,
        :question_id,
        :wire_question_hash,
        :queryables_hash,
        :version,
        :root_id,
        :supersedes_id
      ]
    end

    create :create_version do
      description """
      One person-edited version of an existing proposal chain: the edited
      document arrives PRE-VALIDATED (the edit function ran the full decode
      contract) and the predecessor is superseded in the same transaction
      by the caller. Never called by machinery — the person gate is the
      create policy.
      """

      accept [
        :source,
        :nl_text,
        :nl_digest,
        :document,
        :profile,
        :question_id,
        :wire_question_hash,
        :queryables_hash,
        :version,
        :root_id,
        :supersedes_id
      ]
    end

    update :approve do
      description """
      The person gate. Only an approved document may run, and running stays
      an explicit act — approval itself executes nothing.
      """

      accept []

      validate attribute_equals(:status, :proposed) do
        message "only a proposed document can be approved"
      end

      validate present(:document) do
        message "a refused proposal has no document to approve"
      end

      change set_attribute(:status, :approved)
      require_atomic? false
    end

    update :reject do
      description "The person declines the proposal. Refusal reasons live on refusals; a rejection is a decision."

      accept []

      validate attribute_equals(:status, :proposed) do
        message "only a proposed document can be rejected"
      end

      change set_attribute(:status, :rejected)
      require_atomic? false
    end

    update :supersede do
      description "Marks this version superseded by a newer person edit (versions are superseded, never edited)."

      accept []

      validate attribute_equals(:status, :proposed) do
        message "only a proposed version is superseded by an edit"
      end

      change set_attribute(:status, :superseded)
      require_atomic? false
    end
  end

  policies do
    # The gate: approving, rejecting and superseding are person acts
    # (ADR 0039 — the person is the author of record). A system actor,
    # the ai label, or anything without a user row cannot.
    policy action_type(:update) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    # Proposing is requesting an instrument call; persons do it directly,
    # and system actors (tooling, ADR 0045 advisory posture) may too — but
    # ONLY the propose action: minting edited versions is a person's act,
    # so the bypass does not reach :create_version.
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if action(:propose)
    end

    policy action_type(:create) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end

  @doc """
  Runs the translation mechanism end to end for one natural-language
  search: instrument call → decode under the derived schema → typed pass →
  create. Returns the created record (proposed or refused), or
  `{:error, reason}` when nothing was proposed (profile resolution or
  transport failure — no model output existed to record).

  The profile defaults to `:winnow_generative`, the in-zone generative
  rung. Tests inject `transport: {:fixed, raw}` — a fixed instrument's
  output, skipping the wire entirely while the decode contract runs for
  real.
  """
  @spec propose(keyword()) :: {:ok, t()} | {:error, term()}
  def propose(opts) do
    transport = Keyword.get(opts, :transport, Transport.ReqLLM)
    profile = Keyword.get(opts, :profile, :winnow_generative)
    nl_text = Keyword.fetch!(opts, :nl_text)
    source = Keyword.get(opts, :source, "search")
    prompt = Filter.build_prompt(nl_text, Queryables.all())
    schema = Filter.Schema.schema()

    base = %{
      source: source,
      nl_text: nl_text,
      nl_digest: Canonical.digest(nl_text),
      profile: Atom.to_string(profile),
      question_id: Canonical.question_id(__MODULE__, :exploratory),
      wire_question_hash: Canonical.digest(%{"instructions" => prompt, "schema" => schema}),
      queryables_hash: Queryables.digest(),
      version: 1,
      root_id: nil,
      supersedes_id: nil
    }

    case translate(transport, profile, prompt, schema) do
      {:ok, document, raw_output} ->
        create(
          Map.merge(base, %{status: :proposed, document: document, raw_output: raw_output}),
          opts
        )

      {:refused, reason, raw_output} ->
        create(
          Map.merge(base, %{
            status: :refused,
            document: nil,
            refusal_reason: reason,
            raw_output: raw_output
          }),
          opts
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp create(attrs, opts) do
    __MODULE__
    |> Ash.Changeset.for_create(:propose, attrs,
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant)
    )
    |> Ash.create()
  end

  # The instrument call and the decode pipeline — the question-proposal
  # shape: the transport returns the RAW textual output; every failure
  # keeps the raw output for inspection. `{:fixed, raw}` injects a fixed
  # test instrument's output, skipping the wire entirely.
  defp translate({:fixed, raw}, _profile, _prompt, _schema), do: decode(raw)

  defp translate(transport, profile, prompt, schema) do
    with {:ok, spec, req_llm_opts} <- transport.resolve(profile),
         {:ok, raw_output} <- transport.generate(spec, req_llm_opts, schema, prompt) do
      decode(raw_output)
    end
  end

  defp decode(raw_output) do
    with {:ok, document} <- parse_json(raw_output),
         :ok <- Filter.Schema.validate_document(document),
         {:ok, _ast} <- Document.decode(document, Queryables.all()) do
      {:ok, document, raw_output}
    else
      {:error, reason} when is_binary(reason) ->
        {:refused, reason, raw_output}

      {:error, error} ->
        {:refused, "undecodable output: " <> Exception.message(error), raw_output}
    end
  end

  defp parse_json(raw) do
    case Jason.decode(raw) do
      {:ok, document} -> {:ok, document}
      {:error, error} -> {:error, "output is not JSON: " <> Exception.message(error)}
    end
  end

  @doc """
  The person's edit: validates the edited document through the FULL decode
  contract and stores it as a NEW VERSION — same root, version+1,
  predecessor superseded — in one transaction. A version that fails
  re-validation is refused and nothing is written; the chain is never
  overwritten and never hidden.

  The edit is a document act, not a re-translation: the model is never
  called again, and the new version carries the same NL seed, profile and
  wire hash (the translation observation that seeded the chain), with the
  queryables digest re-taken over the CURRENT vocabulary.
  """
  @spec edit(t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def edit(record, document, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- editable?(record),
         {:ok, _ast} <- validate_edited(document) do
      edit_transaction(record, document, actor, Keyword.get(opts, :tenant))
    end
  end

  defp editable?(%__MODULE__{status: :proposed}), do: :ok

  defp editable?(record) do
    {:error, "only a proposed version can be edited (status: #{record.status})"}
  end

  # Create-then-supersede inside one transaction: any failure before the
  # supersede leaves the chain untouched (the supersede itself raises
  # through the transaction, rolling both back).
  defp edit_transaction(record, document, actor, tenant) do
    __MODULE__
    |> Ash.transaction(fn ->
      case create_version(record, document, actor, tenant) do
        {:ok, version} ->
          supersede(record, actor, tenant)
          {:ok, version}

        {:error, error} ->
          {:error, error}
      end
    end)
    |> case do
      {:ok, {:ok, version}} -> {:ok, version}
      {:ok, {:error, error}} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_edited(document) when is_map(document) do
    Document.decode(document, Queryables.all())
  end

  defp validate_edited(_document) do
    {:error, "the edited document must be a filter document ({\"op\", \"args\"})"}
  end

  defp create_version(record, document, actor, tenant) do
    __MODULE__
    |> Ash.Changeset.for_create(
      :create_version,
      %{
        source: record.source,
        nl_text: record.nl_text,
        nl_digest: record.nl_digest,
        document: document,
        profile: record.profile,
        question_id: record.question_id,
        wire_question_hash: record.wire_question_hash,
        queryables_hash: Queryables.digest(),
        version: record.version + 1,
        root_id: record.root_id || record.id,
        supersedes_id: record.id
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create()
  end

  defp supersede(record, actor, tenant) do
    record
    |> Ash.Changeset.for_update(:supersede, %{}, actor: actor, tenant: tenant)
    |> Ash.update!()
  end

  @doc "Approves the proposal as a person. Executes nothing (Filter.Runner runs an approved document, explicitly)."
  @spec approve(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def approve(record, opts) do
    record
    |> Ash.Changeset.for_update(:approve, %{},
      actor: Keyword.fetch!(opts, :actor),
      tenant: Keyword.get(opts, :tenant)
    )
    |> Ash.update()
  end
end

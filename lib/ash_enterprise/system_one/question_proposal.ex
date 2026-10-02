defmodule AshEnterprise.SystemOne.QuestionProposal do
  @moduledoc """
  A proposed declared question, drafted by an in-zone generative instrument
  from policy text — and nothing more until a person confirms it
  (S1-61 / CAP2-POLICY; ADR 0039, ADR 0046, ADR 0047).

  The mechanism is deliberately boring:

  1. **Propose.** `propose/2` resolves an in-zone profile through the
     ordinary profile machinery (residency guard, region rule), calls the
     transport under the wire schema (`priv/system_one/question_proposal.schema.json`
     — ADR 0046: the schema IS the contract), and decodes. Every candidate
     cites the clause it came from (`clause_ref`). Decoded candidates carry
     their `question_hash` computed by the registry's own
     `Canonical.question_hash/1`, so a confirmed proposal's identity is the
     identity its declaration carries at version 1. An undecodable or
     schema-invalid answer becomes a **refused** proposal with the raw
     output retained — never a best-effort parse.
  2. **Confirm — the person gate.** `confirm` requires a person actor
     (a user row; system actors, automation labels and the `ai` actor all
     fail). The person may EDIT each proposal's wording before confirming;
     the edited entry is re-validated and re-hashed, and the record is
     stamped as confirmed. **Nothing registers on confirmation**: the
     registry is compile-time — the confirmed declaration exists as data
     here, and as nothing else. No question is declared, no judge action
     exists, no observation is recorded, no fact is possible.
  3. **Declare — the person's act.** `to_dsl/2` renders the confirmed
     entry as the exact `judgments do question ... end` snippet. The person
     lands it in the subject resource's source at `version: 1`, and
     commits `priv/judgments/lock.json` (via
     `mix ash_judgments.judgments.lock`): from then on any wording drift is
     a compile error, and a change is a new question — governance by
     construction, ADR 0039 property 6.

  The mechanism is generic by construction: it knows nothing about any
  policy domain. A domain (our own code standards today, a VendorPM custom
  requirement later) contributes only the policy TEXT and, at declaration
  time, the subject resource the questions are judged over.

  ## Instrument-call record

  The proposal records its own instrument interaction: the profile, the
  wire question hash (the digest of the ad-hoc wire question — prompt plus
  schema, the §3.3 discipline for an undeclared question), and the reserved
  exploratory question id (`judgment:v0:<Module>#judgments/exploratory`,
  the S1-56 §4.2 convention). The v0 ledger fragment's `answer_kind` enum
  does not yet admit `extraction` rows, so this record — itself AshEvents-
  audited on the platform base — is where the call is recorded; adopting
  the ledger row for proposal calls is an upstream follow-up, not a host
  workaround.

  `policy_text` and `raw_output` are payload class: person-authored prose
  and model output, erasable, never exported. Everything else — digests,
  ids, statuses, clause refs — is envelope class.
  """

  @type t :: %__MODULE__{}

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false

  alias AshEnterprise.SystemOne.QuestionProposal.Schema
  alias AshEnterprise.SystemOne.QuestionProposal.Transport
  alias AshJudgments.Registry.Canonical

  postgres do
    table "system_one_question_proposals"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      allow_nil?: false,
      default: :proposed,
      public?: true,
      constraints: [one_of: [:proposed, :refused, :confirmed, :rejected]]

    attribute :source, :string,
      allow_nil?: false,
      public?: true,
      description: "Where the policy text came from (a path or name). Envelope class."

    attribute :policy_digest, :string,
      allow_nil?: false,
      public?: true,
      description: "Canonical digest of the policy text (RFC §4.2). Envelope class."

    attribute :policy_text, :string,
      allow_nil?: false,
      public?: false,
      constraints: [trim?: false],
      description:
        "The policy text itself, byte-faithful (the digest is computed over these exact bytes). PAYLOAD CLASS: person-authored prose."

    attribute :proposals, {:array, :map},
      allow_nil?: false,
      default: [],
      public?: true,
      description:
        "The candidate declarations (JSON-safe), each with its clause_ref and question_hash. Data only: nothing is registered from here."

    attribute :refusal_reason, :string,
      public?: true,
      description: "Set when status is refused: why the model output was not decodable."

    attribute :raw_output, :string,
      allow_nil?: true,
      public?: false,
      constraints: [trim?: false],
      description:
        "The model's raw textual output, byte-faithful, retained for inspection — required on refusal. PAYLOAD CLASS."

    attribute :profile, :string,
      allow_nil?: false,
      public?: true,
      description: "The in-zone instrument that drafted the proposal."

    attribute :question_id, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The reserved exploratory question id of the mechanism itself (S1-56 §4.2): judgment:v0:<Module>#judgments/exploratory."

    attribute :wire_question_hash, :string,
      allow_nil?: false,
      public?: true,
      description:
        "Digest of the ad-hoc wire question — prompt plus schema (RFC §3.3 discipline for an undeclared question)."

    create_timestamp :proposed_at
  end

  actions do
    defaults [:read]

    create :propose do
      description """
      Records one propose run. Every field is an input — the instrument was
      called before this create, and replay rebuilds the row without
      consulting a model (the ledger's §6.1 discipline, applied here).
      """

      accept [
        :status,
        :source,
        :policy_digest,
        :policy_text,
        :proposals,
        :refusal_reason,
        :raw_output,
        :profile,
        :question_id,
        :wire_question_hash
      ]
    end

    update :confirm do
      description """
      The person gate. Accepts the (possibly edited) proposals, re-validates
      and re-hashes them, and stamps the record confirmed. Registers
      NOTHING — declaring the question in the registry's DSL is a separate
      act by the same or another person.
      """

      accept [:proposals]

      validate attribute_equals(:status, :proposed) do
        message "only a proposed record can be confirmed"
      end

      change set_attribute(:status, :confirmed)
      require_atomic? false
    end

    update :reject do
      description "The person declines the proposal set. Refusal reasons live on refusals; a rejection is a decision."

      accept []

      validate attribute_equals(:status, :proposed) do
        message "only a proposed record can be rejected"
      end

      change set_attribute(:status, :rejected)
      require_atomic? false
    end
  end

  policies do
    # The gate: confirmation and rejection are person acts (ADR 0039 —
    # activation makes the person the author of record). A system actor,
    # the ai label, or anything without a user row cannot confirm.
    policy action_type(:update) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    # Proposing is requesting an instrument call; persons do it directly,
    # and system actors (tooling, ADR 0045 advisory posture) may too.
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end

  @doc """
  Runs the proposal mechanism end to end for one policy text: instrument
  call → decode → create. Returns the created record, or `{:error, reason}`
  when nothing was proposed (profile resolution or transport failure — no
  model output existed to record).
  """
  @spec propose(keyword()) :: {:ok, t()} | {:error, term()}
  def propose(opts) do
    transport = Keyword.get(opts, :transport, Transport.ReqLLM)
    profile = Keyword.fetch!(opts, :profile)
    policy_text = Keyword.fetch!(opts, :policy_text)
    source = Keyword.fetch!(opts, :source)
    prompt = build_prompt(policy_text, source)

    create_refusable(opts, prompt, profile, transport)
  end

  defp create_refusable(opts, prompt, profile, transport) do
    policy_text = Keyword.fetch!(opts, :policy_text)
    source = Keyword.fetch!(opts, :source)
    actor = Keyword.get(opts, :actor)
    tenant = Keyword.get(opts, :tenant)

    base = %{
      source: source,
      policy_text: policy_text,
      policy_digest: Canonical.digest(policy_text),
      profile: Atom.to_string(profile),
      question_id: Canonical.question_id(__MODULE__, :exploratory),
      wire_question_hash:
        Canonical.digest(%{"instructions" => prompt, "schema" => Schema.schema()})
    }

    case draft(transport, profile, prompt) do
      {:ok, proposals, raw_output} ->
        create(
          base
          |> Map.merge(%{status: :proposed, proposals: proposals, raw_output: raw_output}),
          actor,
          tenant
        )

      {:refused, reason, raw_output} ->
        create(
          base
          |> Map.merge(%{
            status: :refused,
            proposals: [],
            refusal_reason: reason,
            raw_output: raw_output
          }),
          actor,
          tenant
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp create(attrs, actor, tenant) do
    __MODULE__
    |> Ash.Changeset.for_create(:propose, attrs, actor: actor, tenant: tenant)
    |> Ash.create()
  end

  # The instrument call and the decode pipeline. The transport returns the
  # RAW textual output; everything after is this host's decode, and every
  # failure keeps the raw output for inspection. `{:fixed, raw}` injects a
  # fixed test instrument's output, skipping the call entirely — the tests'
  # "fixed test instrument".
  defp draft({:fixed, raw}, _profile, _prompt), do: decode(raw)

  defp draft(transport, profile, prompt) do
    with {:ok, spec, req_llm_opts} <- transport.resolve(profile),
         {:ok, raw_output} <- transport.generate(spec, req_llm_opts, Schema.schema(), prompt) do
      decode(raw_output)
    end
  end

  defp decode(raw_output) do
    with {:ok, document} <- parse_json(raw_output),
         :ok <- Schema.validate_document(document),
         {:ok, proposals} <- normalise_all(document) do
      {:ok, proposals, raw_output}
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

  defp normalise_all(document) do
    document["proposals"]
    |> Enum.map(&normalise_entry/1)
    |> Enum.reduce({:ok, []}, fn
      {:ok, entry}, {:ok, acc} -> {:ok, [entry | acc]}
      {:error, reason}, _ -> {:error, reason}
      _, {:error, reason} -> {:error, reason}
    end)
    |> case do
      {:ok, proposals} -> {:ok, Enum.reverse(proposals)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalise_entry(entry) do
    with {:ok, declaration} <- Schema.normalise(entry) do
      {:ok, Map.put(entry, "question_hash", Schema.question_hash(declaration))}
    end
  end

  @doc """
  Confirms (possibly edited) proposals on a record as a person.

  Re-runs the full decode contract over each entry — confirmation is not a
  rubber stamp, it is the moment the person's wording becomes the
  declaration — recomputes every question hash, and stamps the record.
  Registers nothing anywhere.
  """
  @spec confirm(t(), [map()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def confirm(record, entries, opts \\ []) do
    entries
    |> Enum.map(&normalise_entry/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, entry}, {:ok, acc} -> {:cont, {:ok, [entry | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, reversed} ->
        proposals = Enum.reverse(reversed)

        record
        |> Ash.Changeset.for_update(:confirm, %{proposals: proposals},
          actor: Keyword.fetch!(opts, :actor),
          tenant: Keyword.get(opts, :tenant)
        )
        |> Ash.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Renders one confirmed proposal entry as the exact DSL snippet a person
  lands on the subject resource, at version 1.

  The names, options and families arrive as atom-safe STRINGS (the schema's
  patterns guarantee it) and are rendered verbatim — no atom is minted
  here; the DSL brings them into existence when the person compiles it.
  This is text for a person to review and commit — the declaration is the
  person's act (ADR 0039); nothing writes source code.
  """
  @spec to_dsl(map(), module()) :: String.t()
  def to_dsl(entry, resource_module) do
    name = entry["name"]

    header = "question :#{name} do"
    type_line = "  type #{answer_type_module(entry["answer_type"])}"
    options_line = options_line(entry)
    instructions_line = "  instructions(#{inspect(entry["instructions"])})"
    criteria_line = criteria_line(entry)
    version_line = "  version(1)"
    family_line = "  family(:#{entry["family"]})"
    profile_line = "  profile(:#{entry["profile"]})"
    pii_line = pii_line(entry)
    footer = "end"

    id_comment =
      "  # judgment:v0:#{resource_module |> Module.split() |> Enum.join(".")}#judgments/#{name}"

    Enum.reject(
      [
        header,
        id_comment,
        type_line,
        options_line,
        instructions_line,
        criteria_line,
        version_line,
        family_line,
        profile_line,
        pii_line,
        footer
      ],
      &is_nil/1
    )
    |> Enum.join("\n")
  end

  defp answer_type_module("noul"), do: "AshAi.Evaluate.Noul"
  defp answer_type_module("choice"), do: "AshAi.Evaluate.Choice"
  defp answer_type_module("score"), do: "AshAi.Evaluate.Score"

  defp options_line(%{"answer_type" => "noul"}), do: nil

  defp options_line(%{"answer_type" => "score", "options" => options}) do
    levels = Enum.map_join(options, ", ", &":#{&1}")
    "  constraints(levels: [#{levels}])"
  end

  defp options_line(%{"options" => options}) do
    words = Enum.map_join(options, ", ", &":#{&1}")
    "  constraints(of: [#{words}])"
  end

  defp criteria_line(%{"criteria" => criteria}) when is_map(criteria) and criteria != %{} do
    rendered =
      Enum.map_join(criteria, ",\n", fn {key, text} -> "    #{key}: #{inspect(text)}" end)

    "  criteria(%{\n#{rendered}\n  })"
  end

  defp criteria_line(_entry), do: nil

  defp pii_line(%{"pii" => "minimised"}), do: nil

  defp pii_line(_entry), do: nil

  @doc """
  The prompt sent with the policy text: the decode schema rides the wire as
  the structured-output contract, and the prose says only what the schema
  cannot — cite clauses, never invent vocabulary, never list abstentions.
  """
  @spec build_prompt(String.t(), String.t()) :: String.t()
  def build_prompt(policy_text, source) do
    """
    You are drafting System One question proposals from a policy document.

    Each proposal turns one clause into one declared question a calibrated
    decision model can answer later. Rules, in order of importance:

    - Every proposal cites the clause it came from, by id, in `clause_ref`.
      If a clause cannot become a question, propose nothing for it — vague
      or conflicting clauses are a person's problem, never a guess.
    - Options come ONLY from the clause's own vocabulary, atom-safe and in
      the order the clause lists them. Abstentions are added by the system;
      never list one.
    - `answer_type` is "noul" (a yes/no fact), "choice" (one option from a
      closed set) or "score" (a level). Output only JSON matching the
      provided schema. No extra keys, no commentary.

    Policy document (source: #{source}):

    #{policy_text}
    """
  end
end

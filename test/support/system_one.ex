defmodule AshEnterprise.SystemOne.TestSupport do
  @moduledoc """
  Test-only fixtures for the System One host wiring: a subject resource
  carrying one declared question, and the ReqLLM stand-in that lets the
  judge→recorder path run without a model.

  Compiled only in `:test` (see `elixirc_paths` in mix.exs) and held in a
  domain that is registered nowhere — the same pattern as
  `AshEnterprise.Conformance`. The synthetic wording is the RFC's own
  clinic-demo framing; nothing here is customer-related.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.SystemOne.TestSupport.Note
  end
end

defmodule AshEnterprise.SystemOne.TestSupport.Projections.NoteText do
  @moduledoc """
  The test question's state projection: the model sees the note text and
  nothing else. Defined above the resource it serves — the registry
  transformer reads `state_shape/0` while the resource compiles.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @impl true
  def project(input, _context), do: %{"text" => input.arguments.input["text"]}
end

defmodule AshEnterprise.SystemOne.TestSupport.Note do
  @moduledoc """
  A synthetic free-text subject carrying one declared `record: :must`
  question, so the host test can drive the real judge→recorder path into
  `AshEnterprise.SystemOne.Judgment` — recording through the configured
  host ledger, exactly as a production judge action would.
  """

  use Ash.Resource,
    domain: AshEnterprise.SystemOne.TestSupport,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshAi, AshJudgments.Registry]

  judgments do
    question :notes_follow_up do
      type AshAi.Evaluate.Noul
      instructions("Does the note describe a follow-up commitment?")
      version(1)
      family(:system_one_notes)
      profile(:laya_cpu)
      pii(:minimised)
      state_projection(AshEnterprise.SystemOne.TestSupport.Projections.NoteText)
      state_shape(%{"text" => "string"})
    end
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshEnterprise.SystemOne.Support do
  @moduledoc """
  Shared helpers for the System One host tests: valid observation inputs on
  the fragment's field contract, the judge→recorder drivers, and the
  conformance-style person fixture. Test-only (`test/support`), and the
  only place outside a test that builds judge contexts.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Registry.Canonical

  @doc """
  A valid `:record` input set on the fragment's field contract (RFC §5
  names; the package's `:record` accept list), with per-test overrides.
  """
  def observation_inputs(overrides \\ []) do
    Keyword.merge(
      [
        id: Ash.UUID.generate(),
        question_id:
          "judgment:v0:AshEnterprise.SystemOne.TestSupport.Note#judgments/notes_follow_up",
        question_hash: "sha256:" <> String.duplicate("a", 64),
        question_version: 1,
        family: "system_one_notes",
        subject_type: "note",
        subject_id: "note-1",
        state_digest: Canonical.digest(Canonical.encode(%{"text" => "synthetic"})),
        answer_kind: :noul,
        value: nil,
        probabilities: %{"true" => "0.9", "false" => "0.1"},
        confidence: nil,
        model_spec_requested: "laya:typed-decisions",
        model_version: "test-model-1.0.0",
        model_digest: "sha256:" <> String.duplicate("b", 64),
        runtime_version: "0.9.0",
        profile: "laya_cpu",
        latency_us: 1_234,
        mode: :live,
        correlation_id: nil,
        valid_until: nil
      ],
      overrides
    )
  end

  @doc "Records one observation as the system actor, under the given tenant."
  def record!(opts \\ []) do
    tenant = Keyword.get(opts, :tenant)
    overrides = Keyword.take(opts, [:id, :state_ciphertext])

    Judgment
    |> Ash.Changeset.for_create(:record, observation_inputs(overrides),
      actor: SystemActor.process(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  @doc "Erases the state payload as the system actor (the operator act)."
  def tombstone!(id, opts \\ []) do
    tenant = Keyword.get(opts, :tenant)

    Judgment
    |> Ash.get!(id, actor: SystemActor.process(), tenant: tenant)
    |> Ash.Changeset.for_update(:tombstone_state, %{},
      actor: SystemActor.process(),
      tenant: tenant
    )
    |> Ash.update!()
  end

  @doc """
  Runs the test question's judge action through the real judge→recorder
  path — the host context (`AshEnterprise.SystemOne.judge_context/1`), the
  host ledger config, and the fake model standing in for the wire.
  """
  def judge(opts) do
    tenant = Keyword.get(opts, :tenant)
    actor = Keyword.get(opts, :actor, SystemActor.process())

    context =
      AshEnterprise.SystemOne.judge_context(
        tenant: tenant,
        judgments: %{
          req_llm: AshEnterprise.SystemOne.TestSupport.FakeReqLLM,
          observation_id: Keyword.fetch!(opts, :observation_id),
          subject: %{type: "note", id: "note-1"},
          mode: :live
        }
      )

    AshEnterprise.SystemOne.TestSupport.Note
    |> Ash.ActionInput.for_action(:judge_notes_follow_up, %{"input" => %{"text" => "synthetic"}})
    |> Ash.run_action(actor: actor, tenant: tenant, context: context)
  end

  @doc "Runs the judge path and returns the recorded observation."
  def judge!(opts) do
    {:ok, _answer} = judge(opts)
    observation_id = Keyword.fetch!(opts, :observation_id)

    Judgment
    |> Ash.Query.filter(id == ^observation_id)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "Every recorded observation (authorization off; tests assert on rows)."
  def ledger_rows do
    Ash.read!(Judgment, authorize?: false)
  end

  @doc "The audit events AshEvents wrote for one ledger action on one row."
  def ledger_events(action, record_id) do
    EventLog
    |> Ash.Query.filter(action == ^action and record_id == ^record_id)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  A person actor: a real user row, the way the conformance suite builds
  one — registered, then assigned to a business unit so grant depth can
  resolve. No grants: the System One policies need the actor *kind*, not a
  privilege.
  """
  def person(opts \\ []) do
    tenant = Keyword.get(opts, :tenant, Ash.UUID.generate())

    business_unit =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "system-one-support"},
        authorize?: false,
        tenant: tenant
      )
      |> Ash.create!()

    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "system-one-#{System.unique_integer([:positive])}@example.com",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: business_unit.id},
      authorize?: false
    )
    |> Ash.update!()
    |> Map.put(:organization_id, tenant)
  end

  @doc "Valid `:record` inputs for a human verdict about `judgment`."
  def verdict_inputs(judgment, overrides \\ []) do
    Keyword.merge(
      [
        judgment_id: judgment.id,
        question_hash: judgment.question_hash,
        question_version: judgment.question_version,
        model_digest: judgment.model_digest,
        model_answer: %{
          "kind" => "noul",
          "value" => nil,
          "distribution" => %{"true" => "0.9", "false" => "0.1"}
        },
        model_version: judgment.model_version,
        human_value: "true",
        reason: nil,
        reviewer: "person",
        blind?: true,
        basis: :review_task
      ],
      overrides
    )
  end
end

defmodule AshEnterprise.SystemOne.TestSupport.FakeReqLLM do
  @moduledoc """
  The ReqLLM stand-in for judge tests — a host copy of the package's own
  contract-test fake (`AshJudgments.Test.FakeReqLLM`, MIT, same authorship
  chain), because a dependency's test support does not ship to hosts.

  Upstream `evaluate` accepts a `:req_llm` module override; this fake
  captures what would go over the wire — the resolved model spec, the
  projected state, the question map — and answers with a canned reply, so
  the test drives the real judge→recorder path with zero model calls. It
  runs in the caller's process, so `send(self(), ...)` hands the capture
  to the test.
  """

  def evaluate(model_spec, state, questions, _opts) do
    send(self(), {:judge_call, model_spec, state, questions})

    object = Map.new(questions, fn {key, question} -> {key, canned_answer(question)} end)

    {:ok, %{object: object}}
  end

  defp canned_answer(question) do
    case qtype(question) do
      :score -> canned_score()
      :choice -> canned_choice()
      _kind -> %{"probability" => 0.9}
    end
  end

  # Upstream keeps the question type as an atom in memory.
  defp qtype(question) when is_map(question) do
    type = Map.get(question, :type) || Map.get(question, "type")
    normalize_type(type)
  end

  defp qtype(_other), do: :unknown

  defp normalize_type(nil), do: :unknown
  defp normalize_type(t) when is_atom(t), do: t
  defp normalize_type(t) when is_binary(t), do: String.to_existing_atom(t)
  defp normalize_type(_), do: :unknown

  defp canned_score do
    %{
      "score" => 2,
      "probabilities" => %{"0" => 0.05, "1" => 0.15, "2" => 0.8},
      "confidence" => 0.9,
      "legend" => %{"0" => "None", "1" => "Minor", "2" => "Major"}
    }
  end

  defp canned_choice do
    %{"choice" => "supports", "probabilities" => %{"supports" => 0.9}, "confidence" => 0.9}
  end
end

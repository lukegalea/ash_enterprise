defmodule AshEnterprise.SystemOne.QuestionProposalTest do
  @moduledoc """
  S1-61 / CAP2-POLICY: policy text → proposed declared questions.

  The decode contract against a fixed test instrument (success and every
  refusal path, raw output always retained), the person-confirm gate
  (nothing registers and no facts exist without a person's confirmation,
  and confirmation itself still registers nothing), and the lock
  interaction (a confirmed declaration's hash is the hash the declared
  question carries at version 1, and the lock holds it).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.QuestionProposal
  alias AshEnterprise.SystemOne.QuestionProposal.Schema
  alias AshEnterprise.SystemOne.TestSupport.{FakeTransport, Note, Standard}
  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Registry.Info

  @fixtures_dir Path.expand("../../fixtures/system_one/policy", __DIR__)
  @policy_text File.read!(Path.join(@fixtures_dir, "code_standards_excerpt.md"))
  @valid_output File.read!(Path.join(@fixtures_dir, "recordings/valid.json"))
  @lock_file Path.expand("../../../priv/judgments/lock.json", __DIR__)

  setup do
    Correlation.start_new()

    # The FakeTransport resolves the profile through the real machinery,
    # which resolves {:system, var} transport references at call time.
    System.put_env("OLLAYA_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("S1_GEN_BASE_URL", "http://127.0.0.1:8000/v1")
    System.put_env("S1_GEN_API_KEY", "")

    on_exit(fn ->
      System.delete_env("OLLAYA_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("S1_GEN_BASE_URL")
      System.delete_env("S1_GEN_API_KEY")
    end)

    %{org: Ash.UUID.generate(), person: person()}
  end

  defp raw(name), do: File.read!(Path.join(@fixtures_dir, Path.join("recordings", name)))

  defp propose_fixed(output, ctx, opts \\ []) do
    QuestionProposal.propose(
      [
        source: "test/fixtures/system_one/policy/code_standards_excerpt.md",
        policy_text: @policy_text,
        profile: :laya_cpu,
        transport: {:fixed, output},
        actor: ctx.person,
        tenant: ctx.org
      ]
      |> Keyword.merge(opts)
    )
  end

  # The first fixture proposal, as the propose path would store it: the
  # wire entry plus its computed question hash.
  defp stored_first do
    {:ok, document} = Jason.decode(@valid_output)
    [first | _] = document["proposals"]
    {:ok, declaration} = Schema.normalise(first)
    Map.put(first, "question_hash", Schema.question_hash(declaration))
  end

  describe "decode success (fixed test instrument)" do
    test "a valid output proposes editable candidates carrying registry identity hashes", ctx do
      {:ok, record} = propose_fixed(@valid_output, ctx)

      assert record.status == :proposed
      assert length(record.proposals) == 2
      assert record.policy_digest == Canonical.digest(@policy_text)

      assert record.question_id ==
               "judgment:v0:AshEnterprise.SystemOne.QuestionProposal#judgments/exploratory"

      assert record.wire_question_hash =~ ~r/^sha256:[0-9a-f]{64}$/
      assert record.raw_output == @valid_output

      [first, second] = record.proposals
      assert first["clause_ref"] == "std-1"
      assert first["name"] == "commit_message_imperative"
      assert first["answer_type"] == "choice"
      assert second["clause_ref"] == "std-2"
      assert second["answer_type"] == "noul"

      # The identity continuity is the whole point: the proposal's hash is
      # the hash the declared question carries (Standard declares the
      # confirmed first proposal at version 1).
      declared = Info.question(Standard, :commit_message_imperative)
      assert first["question_hash"] == declared.question_hash
      assert first["question_hash"] == stored_first()["question_hash"]
    end

    test "the proposal alone registers nothing and creates no facts", ctx do
      questions_before = length(Info.questions(Note)) + length(Info.questions(Standard))

      {:ok, _record} = propose_fixed(@valid_output, ctx)

      # The registry is compile-time: a stored proposal is data, nothing
      # else. No question appeared, and no observation / fact exists.
      assert length(Info.questions(Note)) + length(Info.questions(Standard)) == questions_before
      assert ledger_rows() == []
    end

    test "the generative in-zone profile resolves for proposals (S1-61 flag): no real call",
         ctx do
      Application.put_env(:ash_enterprise, :test_transport_output, {:file, "valid.json"})
      on_exit(fn -> Application.delete_env(:ash_enterprise, :test_transport_output) end)

      # The FakeTransport delegates RESOLUTION to the real transport chain
      # (profile guards + generative-wire translation); only the model call
      # is canned. The env vars above satisfy the {:system, var} refs.
      assert {:ok, record} =
               QuestionProposal.propose(
                 source: "recordings",
                 policy_text: @policy_text,
                 profile: :winnow_generative,
                 transport: FakeTransport,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert record.status == :proposed
      assert record.profile == "winnow_generative"
      assert length(record.proposals) == 2
    end

    test "the transport translates the generative profile to the ollama wire", ctx do
      assert {:ok, "ollama:winnow:e4b", opts} =
               AshEnterprise.SystemOne.QuestionProposal.Transport.ReqLLM.resolve(
                 :winnow_generative
               )

      # The transport opts carry the profile's own {:system, var}-resolved
      # endpoint — the value the test itself set above.
      assert Keyword.get(opts, :base_url) == "http://127.0.0.1:11435"
    end

    test "the transport speaks the OpenAI wire to a profile configured for it" do
      {:ok, splash} = AshJudgments.Profile.fetch(:splash_generative)

      assert {:ok, %{provider: :openai, id: id}, opts} =
               AshEnterprise.SystemOne.QuestionProposal.Transport.ReqLLM.resolve(
                 :splash_generative
               )

      assert id == splash.model
      assert Keyword.get(opts, :base_url) == "http://127.0.0.1:8000/v1"
      # A keyless runtime still gets a key sent, so ReqLLM never falls back
      # to OPENAI_API_KEY and hands a hosted vendor's key to the zone host.
      assert Keyword.get(opts, :api_key) == "in-zone-no-key"
      assert Keyword.get(opts, :reasoning_effort) == :none
      assert Keyword.get(opts, :receive_timeout) == 300_000

      # The decode schema rides as a json_schema response format, as written.
      assert Keyword.get(opts, :provider_options) == [
               openai_structured_output_mode: :json_schema,
               openai_json_schema_strict: false
             ]

      # The call record classes it in-zone, like every in-cluster instrument.
      assert %{residency: :in_zone, profile: "splash_generative"} =
               Keyword.fetch!(opts, :model_target)
    end

    test "keywords a runtime only checks after generating stay off its wire schema" do
      alias AshEnterprise.SystemOne.QuestionProposal.Transport

      assert {:ok, _spec, opts} = Transport.ReqLLM.resolve(:splash_generative)
      assert Keyword.get(opts, :wire_schema_drop) == ["pattern", "allOf"]

      wire = Transport.ReqLLM.wire_schema(Schema.schema(), ["pattern", "allOf"])
      refute Jason.encode!(wire) =~ ~s("pattern")
      refute Jason.encode!(wire) =~ ~s("allOf")
      # Everything else rides unchanged; the host decode keeps the full schema.
      assert wire["$defs"]["proposal"]["required"] ==
               Schema.schema()["$defs"]["proposal"]["required"]

      assert Jason.encode!(Schema.schema()) =~ ~s("pattern")
      assert Transport.ReqLLM.wire_schema(Schema.schema(), []) == Schema.schema()
    end

    test "a profile with no configured wire speaks the Ollama-compatible wire" do
      alias AshEnterprise.SystemOne.QuestionProposal.Transport

      assert Transport.ReqLLM.wire(:winnow_generative) == [wire: :ollama]
      assert Transport.ReqLLM.wire(:splash_generative)[:wire] == :openai
    end

    test "a proposal drafted through the Splash profile records it", ctx do
      Application.put_env(:ash_enterprise, :test_transport_output, {:file, "valid.json"})
      on_exit(fn -> Application.delete_env(:ash_enterprise, :test_transport_output) end)

      assert {:ok, record} =
               QuestionProposal.propose(
                 source: "recordings",
                 policy_text: @policy_text,
                 profile: :splash_generative,
                 transport: FakeTransport,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert record.status == :proposed
      assert record.profile == "splash_generative"
    end

    test "resolution runs the real profile machinery with a fake model", ctx do
      Application.put_env(:ash_enterprise, :test_transport_output, {:file, "valid.json"})
      on_exit(fn -> Application.delete_env(:ash_enterprise, :test_transport_output) end)

      assert {:ok, record} =
               QuestionProposal.propose(
                 source: "recordings",
                 policy_text: @policy_text,
                 profile: :laya_cpu,
                 transport: FakeTransport,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert record.status == :proposed
      assert record.profile == "laya_cpu"
      assert length(record.proposals) == 2
    end
  end

  describe "the prompt states the vocabulary rules the schema enforces" do
    # Not every runtime decodes under the wire schema (one that checks
    # `pattern` and the conditional rules only after generating sends them
    # nowhere), so the prose must carry them. These pins hold each rule.
    setup do
      %{prompt: QuestionProposal.build_prompt("POLICY TEXT", "policy.md")}
    end

    test "names, families and options are snake_case atom-safe words", %{prompt: prompt} do
      assert prompt =~ "`name`, `family` and every option word are snake_case identifiers"
      assert prompt =~ "^[a-z][a-z0-9_]{0,63}$"
      assert prompt =~ "No capitals,\n  hyphens, dots or spaces."
    end

    test "a clause term that is not atom-safe maps to snake_case, original kept in criteria",
         %{prompt: prompt} do
      assert prompt =~ "use its snake_case form as the option word"
      assert prompt =~ ~s("Version 2.0"\n  becomes version_2_0)
      assert prompt =~ "keep the\n  original term, verbatim, in that option's `criteria` text"
    end

    test "a noul carries no options", %{prompt: prompt} do
      assert prompt =~ "A noul carries NO `options` key at\n  all"
      assert prompt =~ "A choice or a score must\n  carry `options`."
    end

    test "clause lineage and system-added abstentions still lead", %{prompt: prompt} do
      assert prompt =~ "cites the clause it came from, by id, in `clause_ref`"
      assert prompt =~ "Abstentions are added by\n  the system; never list one."
      assert prompt =~ "Policy document (source: policy.md):\n\nPOLICY TEXT"
    end

    test "a document drafted under the rules decodes", ctx do
      {:ok, record} = propose_fixed(raw("mapped_vocabulary.json"), ctx)

      assert record.status == :proposed
      assert [choice, noul] = record.proposals
      assert choice["options"] == ["mit", "bsd_3_clause", "apache_2_0"]
      assert choice["criteria"]["apache_2_0"] =~ "Apache-2.0"
      refute Map.has_key?(noul, "options")
    end

    test "the same document with the clause's raw terms is still refused by the host", ctx do
      {:ok, document} = Jason.decode(raw("mapped_vocabulary.json"))

      unmapped =
        update_in(document, ["proposals", Access.at(0)], fn entry ->
          entry
          |> Map.put("options", ["MIT", "BSD-3-Clause", "Apache-2.0"])
          |> Map.delete("criteria")
        end)

      {:ok, record} = propose_fixed(Jason.encode!(unmapped), ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "pattern"
    end
  end

  describe "decode refusals (raw output retained, never a guess)" do
    test "output that is not JSON is refused verbatim", ctx do
      malformed = raw("malformed.json")
      {:ok, record} = propose_fixed(malformed, ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "not JSON"
      assert record.raw_output == malformed
      assert record.proposals == []
    end

    test "a wrong answer type is refused, not coerced", ctx do
      {:ok, record} = propose_fixed(raw("wrong_answer_type.json"), ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "must be one of the enum values"
      assert record.raw_output == raw("wrong_answer_type.json")
    end

    test "a ghost option vocabulary (criteria naming undeclared options) is refused", ctx do
      {:ok, record} = propose_fixed(raw("ghost_criteria.json"), ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "criteria keys"
      assert record.raw_output == raw("ghost_criteria.json")
    end

    test "a noul that lists its own options is refused (they are derived)", ctx do
      {:ok, record} = propose_fixed(raw("noul_with_options.json"), ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "json schema validation failed"
      assert record.raw_output == raw("noul_with_options.json")
    end
  end

  describe "the person-confirm gate" do
    test "confirmation is a person act; system machinery and the ai label cannot", ctx do
      {:ok, record} = propose_fixed(@valid_output, ctx)
      entries = record.proposals

      for actor <- [SystemActor.process(), SystemActor.ai()] do
        assert {:error, forbidden} =
                 record
                 |> Ash.Changeset.for_update(:confirm, %{proposals: entries},
                   actor: actor,
                   tenant: ctx.org
                 )
                 |> Ash.update()

        assert forbidden |> Exception.message() =~ ~r/forbidden/i
      end
    end

    test "a person confirms; the registry still registers nothing", ctx do
      {:ok, record} = propose_fixed(@valid_output, ctx)
      questions_before = length(Info.questions(Note)) + length(Info.questions(Standard))

      assert {:ok, confirmed} =
               QuestionProposal.confirm(record, record.proposals,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert confirmed.status == :confirmed

      # Confirmation is a decision about DATA, not a registration: the
      # registry is compile-time, so even a confirmed proposal declares
      # nothing until a person lands the DSL entry.
      assert length(Info.questions(Note)) + length(Info.questions(Standard)) == questions_before
      assert ledger_rows() == []
    end

    test "only a proposed record can be confirmed or rejected", ctx do
      {:ok, record} = propose_fixed(@valid_output, ctx)

      assert {:ok, confirmed} =
               QuestionProposal.confirm(record, record.proposals,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert {:error, %Ash.Error.Invalid{}} =
               QuestionProposal.confirm(confirmed, confirmed.proposals,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert {:error, %Ash.Error.Invalid{}} =
               confirmed
               |> Ash.Changeset.for_update(:reject, %{}, actor: ctx.person, tenant: ctx.org)
               |> Ash.update()
    end

    test "the person edits before confirming; the edited wording is the declaration", ctx do
      {:ok, record} = propose_fixed(@valid_output, ctx)
      original_hash = hd(record.proposals)["question_hash"]

      edited =
        List.update_at(record.proposals, 0, fn entry ->
          Map.put(
            entry,
            "instructions",
            entry["instructions"] <> " Answer from the clause text only."
          )
        end)

      assert {:ok, confirmed} =
               QuestionProposal.confirm(record, edited, actor: ctx.person, tenant: ctx.org)

      edited_entry = hd(confirmed.proposals)
      assert edited_entry["instructions"] =~ "Answer from the clause text only."

      # The edited wording is a NEW identity: the hash follows the words.
      assert edited_entry["question_hash"] != original_hash
      {:ok, declaration} = Schema.normalise(edited_entry)
      assert edited_entry["question_hash"] == Schema.question_hash(declaration)
    end

    test "confirmation re-validates: ghost vocabulary cannot be confirmed", ctx do
      {:ok, record} = propose_fixed(@valid_output, ctx)
      ghost = raw("ghost_criteria.json") |> Jason.decode!() |> Map.get("proposals")

      assert {:error, reason} =
               QuestionProposal.confirm(record, ghost, actor: ctx.person, tenant: ctx.org)

      assert reason =~ "criteria keys"

      reloaded = Ash.reload!(record, authorize?: false)
      assert reloaded.status == :proposed
    end
  end

  describe "lock interaction (governance by construction)" do
    test "the confirmed declaration is locked at version 1, and the declared hash agrees" do
      lock = @lock_file |> File.read!() |> Jason.decode!()

      entry =
        lock[
          "judgment:v0:AshEnterprise.SystemOne.TestSupport.Standard#judgments/commit_message_imperative"
        ]

      assert entry != nil, "the confirmed proposal's declaration must be in the lock"
      assert entry["version"] == 1

      declared = Info.question(Standard, :commit_message_imperative)
      assert entry["hash"] == declared.question_hash

      # And the chain closes: the fixture proposal's hash — what a person
      # would confirm from the fixed instrument — is the same identity.
      assert stored_first()["question_hash"] == declared.question_hash
    end

    test "to_dsl renders the confirmed entry as the person's declaration" do
      entry = Map.put(stored_first(), "profile", "laya_cpu")
      dsl = QuestionProposal.to_dsl(entry, Standard)

      assert dsl =~ "question :commit_message_imperative do"
      assert dsl =~ "type AshAi.Evaluate.Choice"
      assert dsl =~ "constraints(of: [:imperative, :other])"
      assert dsl =~ "version(1)"
      assert dsl =~ "family(:standards_commits)"
      assert dsl =~ "profile(:laya_cpu)"

      assert dsl =~
               "judgment:v0:AshEnterprise.SystemOne.TestSupport.Standard#judgments/commit_message_imperative"

      {:ok, declaration} = Schema.normalise(stored_first())
      assert declaration.name == "commit_message_imperative"
    end
  end
end

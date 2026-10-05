defmodule AshEnterprise.SystemOne.FilterProposalTest do
  @moduledoc """
  S1-65: NL search as an editable filter proposal — the proposal artefact.

  The decode contract against a fixed test instrument (success and every
  refusal path: wrong operator, ghost property, type mismatch — raw output
  always retained, never a best-effort parse), the versioned edit path (a
  person edit mints a NEW version through the full re-validation; a failed
  re-validation writes nothing), the person-approval gate (system
  machinery and the `ai` label cannot approve), and the never-auto-run
  posture (proposing and approving execute nothing and write no
  execution).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Filter.Queryables
  alias AshEnterprise.SystemOne.FilterExecution
  alias AshEnterprise.SystemOne.FilterProposal
  alias AshEnterprise.SystemOne.TestSupport.FakeTransport

  @fixtures_dir Path.expand("../../fixtures/system_one/filter", __DIR__)

  setup do
    Correlation.start_new()

    # The FakeTransport resolves the profile through the real machinery,
    # which resolves {:system, var} transport references at call time.
    System.put_env("OLLAYA_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")

    on_exit(fn ->
      System.delete_env("OLLAYA_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
    end)

    %{org: Ash.UUID.generate(), person: person()}
  end

  defp raw(name), do: File.read!(Path.join([@fixtures_dir, "recordings", name]))

  defp propose_fixed(output, ctx, opts \\ []) do
    FilterProposal.propose(
      [
        nl_text: "vendors in Toronto whose follow-up note holds",
        transport: {:fixed, output},
        actor: ctx.person,
        tenant: ctx.org
      ]
      |> Keyword.merge(opts)
    )
  end

  defp executions do
    FilterExecution |> Ash.read!(authorize?: false)
  end

  describe "decode success (fixed test instrument)" do
    test "a valid output proposes an editable, visible document", ctx do
      {:ok, record} = propose_fixed(raw("valid.json"), ctx)

      assert record.status == :proposed
      assert record.version == 1
      assert record.root_id == nil
      assert record.document["op"] == "and"
      assert record.nl_text =~ "vendors in Toronto"
      assert record.nl_digest =~ ~r/^sha256:[0-9a-f]{64}$/
      assert record.raw_output == raw("valid.json")
      assert record.queryables_hash == Queryables.digest()

      # The translation is a recorded instrument call: the wire question
      # hash (prompt plus schema) and the mechanism's reserved exploratory
      # id — the S1-61 record posture, since the v0 ledger does not admit
      # extraction rows yet.
      assert record.wire_question_hash =~ ~r/^sha256:[0-9a-f]{64}$/

      assert record.question_id ==
               "judgment:v0:AshEnterprise.SystemOne.FilterProposal#judgments/exploratory"
    end

    test "the generative in-zone profile resolves for translations (no real call)", ctx do
      Application.put_env(:ash_enterprise, :test_transport_output, raw("valid.json"))
      on_exit(fn -> Application.delete_env(:ash_enterprise, :test_transport_output) end)

      assert {:ok, record} =
               FilterProposal.propose(
                 nl_text: "urgent follow-ups",
                 profile: :winnow_generative,
                 transport: FakeTransport,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert record.status == :proposed
      assert record.profile == "winnow_generative"
    end

    test "proposing registers nothing and runs nothing", ctx do
      {:ok, _record} = propose_fixed(raw("valid.json"), ctx)

      assert executions() == []
    end
  end

  describe "decode refusals (raw output retained, never a guess)" do
    test "output that is not JSON is refused verbatim", ctx do
      malformed = "not json at all {"
      {:ok, record} = propose_fixed(malformed, ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "not JSON"
      assert record.raw_output == malformed
      assert record.document == nil
    end

    test "an operator outside the Basic profile is refused, not approximated", ctx do
      {:ok, record} = propose_fixed(raw("wrong_operator.json"), ctx)

      # The wire schema refuses it: the operator enum IS the Basic profile.
      assert record.status == :refused
      assert record.refusal_reason =~ "schema validation failed"
      assert record.refusal_reason =~ "must be one of the enum values"
      assert record.raw_output == raw("wrong_operator.json")
    end

    test "a ghost property is refused, never silently skipped", ctx do
      {:ok, record} = propose_fixed(raw("ghost_property.json"), ctx)

      # The wire schema restricts property names to the declared
      # queryables; the refusal names the declared vocabulary.
      assert record.status == :refused
      assert record.refusal_reason =~ "schema validation failed"
      assert record.refusal_reason =~ "one of the enum values"
      assert record.refusal_reason =~ "city"
      assert record.raw_output == raw("ghost_property.json")
    end

    test "a literal that does not type-check against the property is refused", ctx do
      {:ok, record} = propose_fixed(raw("type_mismatch.json"), ctx)

      assert record.status == :refused
      assert record.refusal_reason =~ "does not type-check"
      assert record.raw_output == raw("type_mismatch.json")
    end
  end

  describe "the person-approval gate" do
    test "approval is a person act; system machinery and the ai label cannot", ctx do
      {:ok, record} = propose_fixed(raw("valid.json"), ctx)

      for actor <- [SystemActor.process(), SystemActor.ai()] do
        assert {:error, forbidden} = FilterProposal.approve(record, actor: actor, tenant: ctx.org)
        assert forbidden |> Exception.message() =~ ~r/forbidden/i
      end
    end

    test "a person approves; approval itself executes nothing", ctx do
      {:ok, record} = propose_fixed(raw("valid.json"), ctx)

      assert {:ok, approved} = FilterProposal.approve(record, actor: ctx.person, tenant: ctx.org)
      assert approved.status == :approved

      # NEVER auto-run: an approved proposal is still only a document.
      assert executions() == []
    end

    test "only a proposed document can be approved or rejected", ctx do
      {:ok, record} = propose_fixed(raw("valid.json"), ctx)

      assert {:ok, approved} = FilterProposal.approve(record, actor: ctx.person, tenant: ctx.org)

      assert {:error, %Ash.Error.Invalid{}} =
               FilterProposal.approve(approved, actor: ctx.person, tenant: ctx.org)

      assert {:error, %Ash.Error.Invalid{}} =
               approved
               |> Ash.Changeset.for_update(:reject, %{}, actor: ctx.person, tenant: ctx.org)
               |> Ash.update()
    end

    test "a refused proposal has no document to approve", ctx do
      {:ok, record} = propose_fixed(raw("ghost_property.json"), ctx)

      assert {:error, %Ash.Error.Invalid{}} =
               FilterProposal.approve(record, actor: ctx.person, tenant: ctx.org)
    end

    test "a person may reject; a rejection is a decision", ctx do
      {:ok, record} = propose_fixed(raw("valid.json"), ctx)

      assert {:ok, rejected} =
               record
               |> Ash.Changeset.for_update(:reject, %{}, actor: ctx.person, tenant: ctx.org)
               |> Ash.update()

      assert rejected.status == :rejected
    end
  end

  describe "the versioned edit path" do
    test "a person edit mints a new version; the predecessor is superseded, never overwritten",
         ctx do
      {:ok, v1} = propose_fixed(raw("valid.json"), ctx)

      edited =
        put_in(v1.document, ["args", Access.at(0), "args", Access.at(1)], "Ottawa")

      assert {:ok, v2} = FilterProposal.edit(v1, edited, actor: ctx.person, tenant: ctx.org)

      assert v2.version == 2
      assert v2.root_id == v1.id
      assert v2.supersedes_id == v1.id
      assert v2.status == :proposed
      assert v2.nl_text == v1.nl_text
      assert v2.wire_question_hash == v1.wire_question_hash

      assert get_in(v2.document, ["args", Access.at(0), "args", Access.at(1)]) == "Ottawa"

      reloaded = Ash.get!(FilterProposal, v1.id, authorize?: false)
      assert reloaded.status == :superseded
      # The chain is always visible: the predecessor keeps its document.
      assert reloaded.document["op"] == "and"
    end

    test "a failed re-validation refuses and writes nothing", ctx do
      {:ok, v1} = propose_fixed(raw("valid.json"), ctx)
      versions_before = versions(v1)

      ghost = %{"op" => "=", "args" => [%{"property" => "ghost"}, "x"]}

      assert {:error, reason} = FilterProposal.edit(v1, ghost, actor: ctx.person, tenant: ctx.org)
      assert reason =~ "ghost property"

      assert versions(v1) == versions_before

      reloaded = Ash.reload!(v1, authorize?: false)
      assert reloaded.status == :proposed
      assert reloaded.version == 1
    end

    test "only a proposed version can be edited", ctx do
      {:ok, v1} = propose_fixed(raw("valid.json"), ctx)
      {:ok, approved} = FilterProposal.approve(v1, actor: ctx.person, tenant: ctx.org)

      assert {:error, reason} =
               FilterProposal.edit(approved, approved.document,
                 actor: ctx.person,
                 tenant: ctx.org
               )

      assert reason =~ "only a proposed version"
    end

    defp versions(v1) do
      FilterProposal
      |> Ash.Query.filter(root_id == ^v1.id or id == ^v1.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.id, &1.version, &1.status})
      |> Enum.sort()
    end
  end
end

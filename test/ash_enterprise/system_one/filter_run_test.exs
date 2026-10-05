defmodule AshEnterprise.SystemOne.FilterRunTest do
  @moduledoc """
  S1-65: the run path — a person-APPROVED document compiles
  deterministically and runs over the facts surface.

  Compile truth tables per Basic operator (eq, neq, the four orderings,
  in, and, or, isNull) including the three-valued rows, the status
  clauses for the unknown partition (`<property>.status` with the frozen
  interchange words), three-partition correctness cross-checked against
  the facts the package's own materialiser wrote, the person-approval
  gate at the run level (unapproved proposals NEVER run — asserted), the
  request-time parameters (minimum admission grade, scope), visibility
  narrowing (a judged predicate never widens what the actor may see), and
  the audit rows (final post-edit document + compiled plan + the
  translation-observation digest link).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.Filter.Compiler
  alias AshEnterprise.SystemOne.Filter.Document
  alias AshEnterprise.SystemOne.Filter.Queryables
  alias AshEnterprise.SystemOne.Filter.Runner
  alias AshEnterprise.SystemOne.FilterExecution
  alias AshEnterprise.SystemOne.FilterProposal
  alias AshEnterprise.SystemOne.TestSupport.Note
  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Registry.Info

  @follow_up Info.question(Note, :notes_follow_up).question_id

  @valid_doc %{
    "op" => "=",
    "args" => [%{"property" => @follow_up}, true]
  }

  setup do
    Correlation.start_new()
    %{org: Ash.UUID.generate(), person: person()}
  end

  defp ast(doc), do: elem(Document.decode(doc, Queryables.all()), 1)

  defp eval(doc, facts, now \\ ~U[2026-10-05T12:00:00Z]) do
    Compiler.evaluate(ast(doc), facts, now)
  end

  defp fact(value, holds, overrides \\ []) do
    %{
      value: value,
      holds: holds,
      valid_until: nil,
      scope: nil
    }
    |> Map.merge(Map.new(overrides))
  end

  defp subject(id), do: %{"type" => "commit", "id" => id}

  defp seed(subject_id, predicate, value, holds, opts \\ []) do
    decision =
      %{
        result: :admitted,
        subject: subject(subject_id),
        predicate: predicate,
        value: value,
        holds: holds,
        grade: Keyword.get(opts, :grade, :grant),
        scope: Keyword.get(opts, :scope),
        valid_until: Keyword.get(opts, :valid_until),
        id: Ash.UUID.generate()
      }

    assert {:ok, :materialised} = Materialiser.materialise(decision)
  end

  defp propose_and_approve(ctx, document) do
    {:ok, proposal} =
      FilterProposal.propose(
        nl_text: "test search",
        transport: {:fixed, Jason.encode!(document)},
        actor: ctx.person,
        tenant: ctx.org
      )

    assert {:ok, approved} = FilterProposal.approve(proposal, actor: ctx.person, tenant: ctx.org)
    approved
  end

  defp run!(ctx, approved, opts \\ []) do
    assert {:ok, result} =
             Runner.run(
               approved,
               Keyword.merge([actor: SystemActor.process(), tenant: ctx.org], opts)
             )

    result
  end

  describe "compile truth tables (Kleene three-valued)" do
    test "eq: true / false / unknown-on-absence" do
      doc = %{"op" => "=", "args" => [%{"property" => @follow_up}, true]}

      assert eval(doc, %{}) == :unknown
      assert eval(doc, %{@follow_up => fact(true, true)}) == true
      assert eval(doc, %{@follow_up => fact(false, false)}) == false
    end

    test "neq: present-and-different, present-and-equal, unknown-on-absence" do
      doc = %{"op" => "<>", "args" => [%{"property" => @follow_up}, true]}

      assert eval(doc, %{@follow_up => fact(false, false)}) == true
      assert eval(doc, %{@follow_up => fact(true, true)}) == false
      assert eval(doc, %{}) == :unknown
    end

    test "eq is strict and non-coercing: 80 is not 80.0" do
      doc = %{"op" => "=", "args" => [%{"property" => "hourly_rate"}, 80.0]}
      assert eval(doc, %{"hourly_rate" => fact(80.0, true)}) == true
      assert eval(doc, %{"hourly_rate" => fact(80, true)}) == false
      assert eval(doc, %{"hourly_rate" => fact(80.0, true)}) == true
    end

    test "orderings on numbers, unknown on absence" do
      doc = %{"op" => ">", "args" => [%{"property" => "revenue"}, 70]}

      assert eval(doc, %{"revenue" => fact(80, true)}) == true
      assert eval(doc, %{"revenue" => fact(70, true)}) == false
      assert eval(doc, %{}) == :unknown

      lte = %{"op" => "<=", "args" => [%{"property" => "revenue"}, 80]}
      assert eval(lte, %{"revenue" => fact(80, true)}) == true

      lt = %{"op" => "<", "args" => [%{"property" => "revenue"}, 80]}
      assert eval(lt, %{"revenue" => fact(80, true)}) == false

      gte = %{"op" => ">=", "args" => [%{"property" => "revenue"}, 80]}
      assert eval(gte, %{"revenue" => fact(70, true)}) == false
    end

    test "in: membership, non-membership, unknown left side (local pin)" do
      doc = %{"op" => "in", "args" => [%{"property" => "city"}, ["Toronto", "Ottawa"]]}

      assert eval(doc, %{"city" => fact("Toronto", true)}) == true
      assert eval(doc, %{"city" => fact("Hamilton", true)}) == false
      assert eval(doc, %{}) == :unknown
    end

    test "and: false dominates, then unknown; or: true dominates, then unknown" do
      present = %{"op" => "=", "args" => [%{"property" => "city"}, "Toronto"]}
      absent = %{"op" => "=", "args" => [%{"property" => "revenue"}, 1]}

      conjoin = %{"op" => "and", "args" => [present, absent]}
      assert eval(conjoin, %{"city" => fact("Toronto", true)}) == :unknown
      assert eval(conjoin, %{"city" => fact("Hamilton", true)}) == false

      disjoin = %{"op" => "or", "args" => [present, absent]}
      assert eval(disjoin, %{"city" => fact("Toronto", true)}) == true
      assert eval(disjoin, %{"city" => fact("Hamilton", true)}) == :unknown
    end

    test "isNull: the unknown partition's native spelling" do
      doc = %{"op" => "isNull", "args" => [%{"property" => @follow_up}]}

      assert eval(doc, %{}) == true
      assert eval(doc, %{@follow_up => fact(true, true)}) == false
    end

    test "an expired fact joins unknown and reads stale (S1-56 1.4)" do
      past = ~U[2026-01-01T00:00:00Z]
      now = ~U[2026-10-05T12:00:00Z]

      eq = %{"op" => "=", "args" => [%{"property" => @follow_up}, true]}
      assert eval(eq, %{@follow_up => fact(true, true, valid_until: past)}, now) == :unknown

      status = %{"op" => "=", "args" => [%{"property" => @follow_up <> ".status"}, "stale"]}
      assert eval(status, %{@follow_up => fact(true, true, valid_until: past)}, now) == true
    end

    test "status clauses: the unknown partition's explicit branch" do
      not_assessed = %{
        "op" => "=",
        "args" => [%{"property" => @follow_up <> ".status"}, "not_assessed"]
      }

      assert eval(not_assessed, %{}) == true
      assert eval(not_assessed, %{@follow_up => fact(true, true)}) == false

      admitted = %{
        "op" => "=",
        "args" => [%{"property" => @follow_up <> ".status"}, "admitted_false"]
      }

      assert eval(admitted, %{@follow_up => fact(false, false)}) == true

      # isNull on a status field is always false: status fields are total.
      null_status = %{"op" => "isNull", "args" => [%{"property" => @follow_up <> ".status"}]}
      assert eval(null_status, %{}) == false
    end
  end

  describe "the decode contract" do
    test "a wrong operator is refused" do
      doc = %{"op" => "like", "args" => [%{"property" => "city"}, "Tor%"]}

      assert {:error, reason} = Document.decode(doc, Queryables.all())
      assert reason =~ "unsupported operator"
    end

    test "a ghost property is refused" do
      doc = %{"op" => "=", "args" => [%{"property" => "nope"}, "x"]}

      assert {:error, reason} = Document.decode(doc, Queryables.all())
      assert reason =~ "ghost property"
    end

    test "a type mismatch is refused" do
      doc = %{"op" => ">", "args" => [%{"property" => "city"}, "T"]}

      assert {:error, reason} = Document.decode(doc, Queryables.all())
      assert reason =~ "numeric properties only"
    end

    test "a property-to-property comparison is refused (outside Basic)" do
      doc = %{
        "op" => "=",
        "args" => [%{"property" => "city"}, %{"property" => "revenue"}]
      }

      assert {:error, reason} = Document.decode(doc, Queryables.all())
      assert reason =~ "outside the Basic profile"
    end
  end

  describe "three-partition correctness over the facts surface" do
    test "in / out / unknown agree with the facts the materialiser wrote", ctx do
      seed("c-1", @follow_up, true, true)
      seed("c-2", @follow_up, false, false)
      # c-3 exists in the surface (a crisp fact) but has no follow-up
      # fact: not assessed. A subject with no facts at all is not in the
      # facts surface — there is no subject registry at this slice.
      seed("c-3", "licence_current", true, true)

      approved = propose_and_approve(ctx, @valid_doc)
      result = run!(ctx, approved)

      assert subject_ids(result.partitions.in) == ["c-1"]
      assert subject_ids(result.partitions.out) == ["c-2"]
      assert [%{"subject_id" => "c-3", "missing" => missing}] = result.partitions.unknown
      assert missing == [@follow_up]

      assert result.counts == %{in: 1, out: 1, unknown: 1}

      # Cross-check against the package's own tri-state reading: the fact
      # the materialiser wrote for c-1 carries holds=true (in), c-2's
      # carries holds=false (out), c-3 has no follow-up fact (unknown).
      assert current_holds("c-1", @follow_up) == true
      assert current_holds("c-2", @follow_up) == false
      assert current_holds("c-3", @follow_up) == nil

      # The unknown partition surfaces the assess action's existence.
      assert result.assess.action == :assess
      assert result.assess.pending == 1
    end

    test "a crisp predicate composes with a judged one; unknown propagates", ctx do
      seed("c-1", "city", "Toronto", true)
      seed("c-1", @follow_up, true, true)
      seed("c-2", "city", "Toronto", true)
      # c-2 has no follow-up fact: the conjunction is UNKNOWN for it, and
      # it is never folded into out.

      doc = %{
        "op" => "and",
        "args" => [
          %{"op" => "=", "args" => [%{"property" => "city"}, "Toronto"]},
          @valid_doc
        ]
      }

      approved = propose_and_approve(ctx, doc)
      result = run!(ctx, approved)

      assert subject_ids(result.partitions.in) == ["c-1"]
      assert result.partitions.out == []
      assert subject_ids(result.partitions.unknown) == ["c-2"]
    end

    test "the status clause recovers the unknown partition explicitly", ctx do
      # c-1 is assessed (admitted_true); c-2 exists in the surface but has
      # no follow-up fact.
      seed("c-1", @follow_up, true, true)
      seed("c-2", "licence_current", true, true)

      doc = %{
        "op" => "=",
        "args" => [%{"property" => @follow_up <> ".status"}, "not_assessed"]
      }

      approved = propose_and_approve(ctx, doc)
      result = run!(ctx, approved)

      # Status fields are total, so a matching subject is genuinely IN:
      # "show me what has not been assessed" returns exactly c-2. c-1 is
      # present-and-different: excluded with data (out), never unknown.
      assert subject_ids(result.partitions.in) == ["c-2"]
      assert subject_ids(result.partitions.out) == ["c-1"]
      assert result.partitions.unknown == []
    end

    test "stale facts join unknown via the run path too", ctx do
      seed("c-1", @follow_up, true, true, valid_until: ~U[2026-01-01T00:00:00Z])

      approved = propose_and_approve(ctx, @valid_doc)
      result = run!(ctx, approved)

      assert result.partitions.in == []
      assert [%{"subject_id" => "c-1", "missing" => [@follow_up]}] = result.partitions.unknown
    end

    test "min_grade is a request-time parameter: a person floor hides grant facts", ctx do
      seed("c-1", @follow_up, true, true, grade: :grant)
      seed("c-1", "licence_current", true, true, grade: :person)

      approved = propose_and_approve(ctx, @valid_doc)

      # At the person floor the grant-grade follow-up fact is invisible:
      # the subject stays in the surface (its person-grade crisp fact),
      # but the judged predicate reads not-assessed for it.
      result = run!(ctx, approved, min_grade: :person)
      assert result.partitions.in == []
      assert [%{"subject_id" => "c-1", "missing" => [@follow_up]}] = result.partitions.unknown
      assert result.execution.min_grade == :person

      result = run!(ctx, approved, min_grade: :grant)
      assert subject_ids(result.partitions.in) == ["c-1"]
    end

    test "scope binds at request time; the document stays scope-free", ctx do
      seed("c-1", @follow_up, true, true)
      seed("c-2", @follow_up, true, true, scope: %{"tenant_id" => "t-1"})

      approved = propose_and_approve(ctx, @valid_doc)

      result = run!(ctx, approved, scope: %{"tenant_id" => "t-1"})
      assert subject_ids(result.partitions.in) == ["c-2"]
      assert result.execution.scope == %{"tenant_id" => "t-1"}
      assert result.execution.plan["scope"] == %{"tenant_id" => "t-1"}
    end
  end

  describe "the gates and the audit" do
    test "an unapproved proposal NEVER runs (asserted)", ctx do
      {:ok, proposed} =
        FilterProposal.propose(
          nl_text: "test search",
          transport: {:fixed, Jason.encode!(@valid_doc)},
          actor: ctx.person,
          tenant: ctx.org
        )

      assert {:error, reason} =
               Runner.run(proposed, actor: SystemActor.process(), tenant: ctx.org)

      assert reason =~ "not approved"
      assert executions() == []
    end

    test "a judged predicate never widens actor visibility: a grantless person sees nothing",
         ctx do
      seed("c-1", @follow_up, true, true)

      approved = propose_and_approve(ctx, @valid_doc)

      # The person has no role grants, so their own read of the facts
      # surface narrows to nothing — the fold sees only what their read
      # returned (an empty universe), never the rows a wider actor sees.
      assert {:ok, result} = Runner.run(approved, actor: ctx.person, tenant: ctx.org)

      assert result.counts == %{in: 0, out: 0, unknown: 0}

      # The same document, run as a system actor, sees the partition.
      result = run!(ctx, approved)
      assert subject_ids(result.partitions.in) == ["c-1"]
    end

    test "a refused or rejected proposal cannot run", ctx do
      {:ok, refused} =
        FilterProposal.propose(
          nl_text: "test search",
          transport: {:fixed, "garbage"},
          actor: ctx.person,
          tenant: ctx.org
        )

      assert {:error, reason} = Runner.run(refused, actor: SystemActor.process(), tenant: ctx.org)
      assert reason =~ "not approved"
    end

    test "a vocabulary change between edit and run is a refusal, never a drift", ctx do
      # A stored proposal whose queryables digest no longer matches the
      # current vocabulary (a declaration change after validation): the
      # in-memory struct exercises the runner's re-check directly.
      drifted = %FilterProposal{
        id: Ash.UUID.generate(),
        status: :approved,
        document: @valid_doc,
        queryables_hash: "sha256:" <> String.duplicate("0", 64),
        wire_question_hash: "sha256:" <> String.duplicate("1", 64),
        nl_digest: "sha256:" <> String.duplicate("2", 64),
        version: 1
      }

      assert {:error, reason} = Runner.run(drifted, actor: SystemActor.process(), tenant: ctx.org)
      assert reason =~ "declared queryables changed"
    end

    test "every run audits the final document, the plan and the seed links", ctx do
      seed("c-1", @follow_up, true, true)
      approved = propose_and_approve(ctx, @valid_doc)

      run!(ctx, approved)
      run!(ctx, approved)

      assert [first, second] = executions()
      assert length(first.id |> String.graphemes()) == 36

      for execution <- [first, second] do
        assert execution.proposal_id == approved.id
        assert execution.proposal_version == approved.version
        assert execution.document == approved.document
        assert execution.plan["predicates"] == [@follow_up]
        assert execution.plan["operators"] == ["eq"]
        assert execution.plan["strategy"] == "surface_fold"
        assert execution.wire_question_hash == approved.wire_question_hash
        assert execution.nl_digest == approved.nl_digest
        assert execution.min_grade == :grant
      end

      assert first.in_count == 1 and first.out_count == 0 and first.unknown_count == 0
      assert second.in_count == 1
    end
  end

  defp subject_ids(partition), do: Enum.map(partition, & &1["subject_id"])

  defp executions do
    FilterExecution |> Ash.Query.sort(:ran_at) |> Ash.read!(authorize?: false)
  end

  defp current_holds(subject_id, predicate) do
    Fact
    |> Ash.Query.filter(
      subject_id == ^subject_id and predicate == ^predicate and is_nil(superseded_by)
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.holds)
    |> case do
      [] -> nil
      [holds] -> holds
    end
  end
end

defmodule AshEnterprise.Documents.PaperDraftTest do
  @moduledoc """
  R10, the governed path: draft → a person approves → issue. An approved draft
  is issued exactly as rendered, and only while nothing it was made from has
  moved; a source change after approval makes it stale, and a stale draft is
  never issued. Every `issue_draft` outcome is recorded on the draft. SYNTHETIC
  content only — the person's rows are seeded entries the `activity_summary`
  kind reads back as them, and a "source change" is a change to those rows.
  """

  use AshEnterprise.DataCase, async: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Decisions.{Definition, Evaluation}
  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Actions.{Draft, Issue}
  alias AshEnterprise.Documents.Paper.Fingerprint
  alias AshEnterprise.Documents.PaperClause
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Binding
  alias AshEnterprise.Test.Paper.ClauseTables
  alias AshEnterprise.Test.{PaperEntries, PaperFacts}
  alias AshPaper.{Payload, Render}

  @moduletag :evidence

  @title "Activity summary 2025"
  @key "hazard_note"
  @decision_key "paper.clause." <> @key

  @checker_grants [
    {PaperClause, :create, :global},
    {PaperClause, :read, :global},
    {PaperClause, :write, :global}
  ]

  setup do
    admin = tenant!()
    admit_clause(admin)
    bind(admin, "carlito")
    PaperEntries.seed!(admin, rows())
    # The Hazard entry's follow-up question, answered: these tests are about drafts.
    PaperFacts.answer_all!(admin, "activity_summary", PaperEntries.subject(), @title)
    {:ok, admin: admin}
  end

  describe "draft, approve, issue" do
    test "an unchanged source issues the approved bytes, and the run becomes :issued", %{
      admin: admin
    } do
      draft = draft!(admin)

      assert draft.check_status == :correct
      assert draft.disposition == :proposed
      assert draft.freshness == :current
      assert draft.index == 0
      assert draft.owner_id == admin.actor.id

      run = run!(admin, draft.run_id)
      assert run.stage == :draft
      assert run.read_back_status == :passed
      refute loaded_issued?(admin, run)

      # The fingerprint's payload hash is keyed as the run keys it: it is the
      # run snapshot's own payload hash.
      assert {:ok, fingerprint} = Fingerprint.unseal(draft, admin.tenant)
      assert fingerprint["payload_hash"] == run.snapshot["snapshot"]["payload_hash"]
      assert fingerprint["output_digest"] == run.output_digest

      assert [%{"key" => @key, "include" => true, "rule_ids" => ["rule_hazard_expenses"]}] =
               fingerprint["decisions"]

      Documents.approve_paper_draft!(draft, %{}, as(admin))

      assert {:ok, issued} = Documents.issue_paper_draft(draft.id, as(admin))

      # The same run, now issued, with no re-render: the digest is unchanged
      # and the stored bytes hash to it.
      assert issued.id == run.id
      assert issued.stage == :issued
      assert issued.output_digest == run.output_digest
      assert issued.snapshot == run.snapshot
      assert sha256(version_for(admin, issued).bytes) == run.output_digest
      assert loaded_issued?(admin, issued)
      assert {:ok, [_only_run]} = Documents.my_paper_runs(as(admin))

      applied = reload(admin, draft)
      assert applied.disposition == :applied
      assert applied.applied_by_actor_id == admin.actor.id

      assert [%{"outcome" => "issued", "output_digest" => digest} = outcome] =
               applied.issue_outcomes

      assert digest == run.output_digest

      # The outcome is stored unsealed: it names no person.
      refute Map.has_key?(outcome, "actor_id")

      stored =
        AshEnterprise.Repo.query!("SELECT issue_outcomes::text FROM paper_drafts WHERE id = $1", [
          Ecto.UUID.dump!(draft.id)
        ]).rows

      assert [[json]] = stored
      refute json =~ "actor"
      refute json =~ admin.actor.id
    end

    test "a one-step issue keeps its meaning: stage :issued", %{admin: admin} do
      assert {:ok, run} =
               Documents.issue_paper_run(
                 "activity_summary",
                 PaperEntries.subject(),
                 @title,
                 as(admin)
               )

      assert run.stage == :issued
      assert loaded_issued?(admin, run)
    end
  end

  describe "staleness: anything moved after approval refuses the issue" do
    test "a source value changes: stale, refused, and apply is impossible", %{admin: admin} do
      draft = approved_draft!(admin)
      PaperEntries.change!(admin, "Hazard", %{amount: "-41"})

      assert %Paper.Error{reason: {:draft_stale, [:payload]}} =
               unwrap(Documents.issue_paper_draft(draft.id, as(admin)))

      stale = reload(admin, draft)
      assert stale.freshness == :stale
      assert stale.disposition == :approved
      assert [%{"outcome" => "stale", "moved" => ["payload"]}] = stale.issue_outcomes

      # The fragment's freshness guard: no apply, however it is reached.
      assert {:error, error} = Documents.apply_paper_draft(stale, %{}, as(admin))
      assert Exception.message(error) =~ "stale"

      # A second attempt, even with the rows put back, is refused and recorded.
      PaperEntries.change!(admin, "Hazard", %{amount: "-40"})

      assert %Paper.Error{reason: {:draft_not_current, :stale}} =
               unwrap(Documents.issue_paper_draft(draft.id, as(admin)))

      assert [_stale, %{"outcome" => "refused", "reason" => reason}] =
               reload(admin, draft).issue_outcomes

      assert reason =~ "draft_not_current"
      assert run!(admin, draft.run_id).stage == :draft
    end

    test "the binding is rebound", %{admin: admin} do
      draft = approved_draft!(admin)
      rebind(admin, "caladea")

      assert_stale(admin, draft, [:binding])
    end

    test "a newly admitted clause version", %{admin: admin} do
      draft = approved_draft!(admin)

      checker = member!(admin, role_name(), @checker_grants)
      admit_clause(admin, drafter: checker.actor, runs: revised_runs())

      assert_stale(admin, draft, [:clause_pins])
    end

    test "a newly published decision version", %{admin: admin} do
      draft = approved_draft!(admin)

      revised =
        String.replace(
          ClauseTables.xml(@key),
          "the hazard note explains the follow-up.",
          "the hazard note explains the follow-up (revised)."
        )

      publish_variant(admin.tenant, revised)

      # Same rules, same answer: only the definition moved.
      assert_stale(admin, draft, [:decision_definitions])
    end

    test "a decision now answering differently", %{admin: admin} do
      draft = approved_draft!(admin)

      # No Hazard row any more: the table now answers exclude, by another rule.
      PaperEntries.change!(admin, "Hazard", %{category: "Groceries"})
      moved = assert_stale(admin, draft, nil)
      assert :decisions in moved
      assert :payload in moved
      refute :decision_definitions in moved
    end

    test "the recompute writes nothing: no decision evaluation is recorded", %{admin: admin} do
      draft = approved_draft!(admin)
      {:ok, fingerprint} = Fingerprint.unseal(draft, admin.tenant)
      run = run!(admin, draft.run_id)
      before = evaluations(admin)

      assert Fingerprint.moved(fingerprint, run, admin.actor, admin.tenant) == []

      PaperEntries.change!(admin, "Hazard", %{category: "Groceries"})
      assert :decisions in Fingerprint.moved(fingerprint, run, admin.actor, admin.tenant)

      assert evaluations(admin) == before
    end

    test "rows that change between the check and the apply are caught by the apply", %{
      admin: admin
    } do
      draft = approved_draft!(admin)

      # `issue_draft` checked and found nothing moved; then the rows move
      # before its apply commits. The apply recomputes inside its own
      # transaction, so the apply is refused and nothing is issued.
      PaperEntries.change!(admin, "Hazard", %{amount: "-41"})

      assert {:error, error} = Documents.apply_paper_draft(draft, %{}, as(admin))
      assert Exception.message(error) =~ "payload"
      assert reload(admin, draft).disposition == :approved
      assert run!(admin, draft.run_id).stage == :draft

      # The next issue_draft names it and marks the draft stale.
      assert %Paper.Error{reason: {:draft_stale, [:payload]}} =
               unwrap(Documents.issue_paper_draft(draft.id, as(admin)))
    end
  end

  describe "a tenant whose binding activated no clause" do
    # A tenant of its own: no wording admitted and no clause table published.
    setup do
      bare = tenant!()
      bind(bare, "carlito", publish_table?: false)
      PaperEntries.seed!(bare, rows())
      PaperFacts.answer_all!(bare, "activity_summary", PaperEntries.subject(), @title)
      {:ok, bare: bare}
    end

    test "drafts and issues, and the fingerprint decides no clause", %{bare: bare} do
      draft = approved_draft!(bare)

      assert {:ok, fingerprint} = Fingerprint.unseal(draft, bare.tenant)
      assert fingerprint["clause_pins"] == []
      assert fingerprint["decision_definitions"] == []
      assert fingerprint["decisions"] == []

      assert {:ok, issued} = Documents.issue_paper_draft(draft.id, as(bare))
      assert issued.stage == :issued
      assert issued.clause_reasons == []
    end

    test "admitting a clause after approval moves the clause pins only", %{bare: bare} do
      draft = approved_draft!(bare)
      admit_clause(bare)

      # The binding still activates no clause, so nothing is decided and no
      # table is needed to show the decisions current; the new wording is a
      # pin the binding does not hold.
      assert_stale(bare, draft, [:clause_pins])
    end
  end

  describe "refusals" do
    test "an unapproved draft is refused, and the refusal is recorded", %{admin: admin} do
      draft = draft!(admin)

      assert %Paper.Error{reason: {:draft_not_approved, :proposed}} =
               unwrap(Documents.issue_paper_draft(draft.id, as(admin)))

      reloaded = reload(admin, draft)
      assert reloaded.disposition == :proposed
      assert reloaded.freshness == :current
      assert [%{"outcome" => "refused", "reason" => reason}] = reloaded.issue_outcomes
      assert reason =~ "draft_not_approved"
      assert run!(admin, draft.run_id).stage == :draft
    end

    test "a draft whose read-back failed or was unmeasured cannot be approved", %{admin: admin} do
      assert Draft.check_status(:passed) == :correct
      assert Draft.check_status(:failed) == :incorrect
      assert Draft.check_status(:unmeasured) == :incomplete
      assert Draft.check_status(:not_run) == :incomplete

      failed = drafted_with_read_back(admin, :failed)
      assert failed.check_status == :incorrect

      unmeasured = drafted_with_read_back(admin, :unmeasured)
      assert unmeasured.check_status == :incomplete

      for draft <- [failed, unmeasured] do
        assert {:error, error} = Documents.approve_paper_draft(draft, %{}, as(admin))
        assert Exception.message(error) =~ "only a correct candidate is approved"
        assert reload(admin, draft).disposition == :proposed
      end
    end

    test "machinery cannot approve or apply, and a person cannot mark stale", %{admin: admin} do
      draft = draft!(admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Documents.approve_paper_draft(draft, %{}, machinery(admin))

      approved = Documents.approve_paper_draft!(draft, %{}, as(admin))

      assert {:error, %Ash.Error.Forbidden{}} =
               Documents.apply_paper_draft(approved, %{}, machinery(admin))

      assert {:error, %Ash.Error.Forbidden{}} =
               Documents.mark_paper_draft_stale(approved, %{}, as(admin))

      still = reload(admin, draft)
      assert still.disposition == :approved
      assert still.freshness == :current
      assert run!(admin, draft.run_id).stage == :draft
    end

    test "a rejected draft cannot be issued", %{admin: admin} do
      draft = draft!(admin)
      Documents.reject_paper_draft!(draft, %{}, as(admin))

      assert %Paper.Error{reason: {:draft_not_approved, :rejected}} =
               unwrap(Documents.issue_paper_draft(draft.id, as(admin)))

      assert [%{"outcome" => "refused"}] = reload(admin, draft).issue_outcomes
      assert run!(admin, draft.run_id).stage == :draft
    end

    test "a superseded draft cannot be issued", %{admin: admin} do
      draft = approved_draft!(admin)
      Documents.supersede_paper_draft!(draft, %{}, machinery(admin))

      assert %Paper.Error{reason: {:draft_not_approved, :superseded}} =
               unwrap(Documents.issue_paper_draft(draft.id, as(admin)))

      assert {:error, _guard} = Documents.apply_paper_draft(reload(admin, draft), %{}, as(admin))
      assert [%{"outcome" => "refused"}] = reload(admin, draft).issue_outcomes
      assert run!(admin, draft.run_id).stage == :draft
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp as(admin), do: [actor: admin.actor, tenant: admin.tenant]
  defp machinery(admin), do: [actor: SystemActor.oban(), tenant: admin.tenant]

  defp draft!(admin) do
    Documents.draft_paper_run!("activity_summary", PaperEntries.subject(), @title, as(admin))
  end

  defp approved_draft!(admin) do
    admin |> draft!() |> Documents.approve_paper_draft!(%{}, as(admin))
  end

  defp reload(admin, draft), do: Documents.get_paper_draft!(draft.id, as(admin))

  defp run!(admin, id),
    do: Documents.get_paper_run!(id, tenant: admin.tenant, authorize?: false)

  defp loaded_issued?(admin, run) do
    run |> Ash.load!(:issued?, tenant: admin.tenant, authorize?: false) |> Map.fetch!(:issued?)
  end

  # Refused as stale naming `expected` (or anything, when nil), marked stale,
  # recorded, apply impossible and the run still a draft. Returns what moved.
  defp assert_stale(admin, draft, expected) do
    assert %Paper.Error{reason: {:draft_stale, moved}} =
             unwrap(Documents.issue_paper_draft(draft.id, as(admin)))

    if expected, do: assert(moved == expected)

    stale = reload(admin, draft)
    assert stale.freshness == :stale
    assert [%{"outcome" => "stale", "moved" => recorded}] = stale.issue_outcomes
    assert recorded == Enum.map(moved, &Atom.to_string/1)
    assert {:error, _guard} = Documents.apply_paper_draft(stale, %{}, as(admin))
    assert run!(admin, draft.run_id).stage == :draft

    moved
  end

  # A draft-stage run rendered and stored, read back against a tampered
  # payload (`:failed`) or unreadable bytes (`:unmeasured`), then proposed the
  # way `draft` proposes.
  defp drafted_with_read_back(admin, outcome) do
    {:ok, schema, layout, theme} = Paper.definition("activity_summary")

    {:ok, payload} =
      Payload.build(schema, PaperEntries.source(rows()), title: @title, locale: :en)

    {:ok, run} =
      Issue.start_run("activity_summary", binding_for(admin).id, as(admin), :draft)

    {:ok, rendered} = Render.render(layout, theme, payload, [], Paper.limits())
    {:ok, version} = Issue.ingest(admin.tenant, rendered.bytes)
    {:ok, run} = Issue.record_render(run, schema, layout, theme, payload, rendered)

    {checked_payload, bytes} =
      case outcome do
        :failed ->
          {:ok, tampered} =
            Payload.build(schema, %{PaperEntries.source(rows()) | year: 2099},
              title: @title,
              locale: :en
            )

          {tampered, rendered.bytes}

        :unmeasured ->
          {payload, <<0, 1, 2, 3, "not a pdf">>}
      end

    {:ok, run} =
      Issue.read_back_and_record(run, version.id, checked_payload, bytes, rendered.marks, theme)

    assert run.read_back_status == outcome

    {:ok, draft} = Draft.propose(run, %{"v" => 1}, admin.tenant)
    draft
  end

  defp version_for(admin, run) do
    AshEvidence.DocumentVersion
    |> Ash.Query.filter(sha256 == ^run.output_digest)
    |> Ash.read_one!(tenant: admin.tenant, authorize?: false)
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp unwrap({:error, %Paper.Error{} = error}), do: error

  defp unwrap({:error, class}) do
    assert [inner] = Enum.filter(class.errors, &match?(%Paper.Error{}, &1))
    inner
  end

  defp role_name, do: "paper-clerk-#{System.unique_integer([:positive])}"

  # `admin` drafts; a member admits — maker-checker through the grant model.
  defp admit_clause(admin, opts \\ []) do
    drafter = Keyword.get(opts, :drafter, admin.actor)
    runs = Keyword.get(opts, :runs, note_runs())
    checker = member!(admin, role_name(), @checker_grants)

    clause =
      Documents.draft_paper_clause!(@key, :en, %{runs: runs},
        actor: drafter,
        tenant: admin.tenant
      )

    clause
    |> Documents.measure_paper_clause_impact!(actor: checker.actor, tenant: admin.tenant)
    |> Documents.admit_paper_clause!(actor: checker.actor, tenant: admin.tenant)
  end

  defp note_runs, do: [%{"kind" => "text", "value" => "Hazard follow-up explained."}]
  defp revised_runs, do: [%{"kind" => "text", "value" => "Revised hazard follow-up wording."}]

  # Publishes the clause table too, unless `publish_table?: false`.
  defp bind(admin, theme_name, opts \\ []) do
    if Keyword.get(opts, :publish_table?, true), do: ClauseTables.publish!(admin.tenant, @key)

    Documents.bind_paper!(
      "activity_summary",
      Paper.binding_purpose(),
      %{selection: selection(admin, theme_name), backend_profile_hash: profile_hash()},
      as(admin)
    )
  end

  defp rebind(admin, theme_name) do
    Documents.rebind_paper!(
      binding_for(admin),
      %{selection: selection(admin, theme_name), backend_profile_hash: profile_hash()},
      as(admin)
    )
  end

  defp binding_for(admin) do
    Documents.get_paper_binding_by_selector!(
      Paper.binding_selector("activity_summary"),
      as(admin)
    )
  end

  defp selection(admin, theme_name) do
    {:ok, schema, _layout, _theme} = Paper.definition("activity_summary")
    Paper.selection(schema, Paper.layout(), Paper.theme(theme_name), admin.tenant)
  end

  defp profile_hash, do: AshPaper.Binding.backend_profile_hash(%{"typst" => "pinned"})

  # A table published as the next version of the same key and bound, so the
  # tenant resolves it from now on.
  defp publish_variant(tenant, xml) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    definition =
      Definition
      |> Ash.Changeset.for_create(:create, %{key: @decision_key, name: @key, xml: xml}, opts)
      |> Ash.create!(opts)

    # Publishing rests on what the version would change (R4): measured first.
    published =
      definition
      |> AshEnterprise.Decisions.measure_definition_impact!(opts)
      |> Definition.publish!(opts)

    Binding.bind!(
      %{
        kind: :decision,
        key: @decision_key,
        source: :tenant,
        target_id: published.id,
        bound_version: published.version
      },
      opts
    )

    published
  end

  defp evaluations(admin),
    do: Evaluation |> Ash.read!(tenant: admin.tenant, authorize?: false) |> length()

  # Synthetic: CAD rows in 2025, one of them a Hazard.
  defp rows do
    [{"a", "2025-01-02", "-20", "Groceries"}, {"b", "2025-07-15", "-40", "Hazard"}]
  end
end

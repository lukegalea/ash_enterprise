defmodule AshEnterprise.Documents.PaperTest do
  @moduledoc """
  The host half of the paper kernel's phase 1, over the SYNTHETIC
  `activity_summary` kind: the same payload in two themes says the same
  things; two schemas over one layout share page furniture; the same inputs
  are the same bytes and the same evidence row; and every failure the kernel
  defines is visible, never a pass. No real data is touched — the person's
  rows are seeded entries (`AshEnterprise.Test.PaperEntries`), which the kind
  reads back as them.
  """

  use AshEnterprise.DataCase, async: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Actions.Issue
  alias AshEnterprise.Documents.Paper.Error, as: PaperError
  alias AshEnterprise.Documents.{PaperClause, PaperRun}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Test.Paper.ActivitySummary
  alias AshEnterprise.Test.Paper.ClauseTables
  alias AshEnterprise.Test.{PaperEntries, PaperFacts}
  alias AshPaper.{Payload, Pdf, Render, Theme, Verify}

  @moduletag :evidence

  @title "Activity summary 2025"

  setup do
    admin = tenant!()
    PaperEntries.seed!(admin)
    {:ok, admin: admin}
  end

  describe "issue, end to end" do
    test "an issue renders, stores the bytes and passes its read-back", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")

      run = issue!(admin, "activity_summary")

      assert run.render_status == :rendered
      assert run.read_back_status == :passed
      assert run.output_digest =~ ~r/\A[0-9a-f]{64}\z/
      assert run.problems == []

      version = version_for(admin, run)
      assert version.kind == "application/pdf"
      assert byte_size(version.bytes) > 0

      # The read-back pass is a closed ParseRun of this instrument.
      parse_run = parse_run_for(admin, version.id)
      assert parse_run.status == :ok
      assert parse_run.config["outcome"] == "passed"
      assert parse_run.config["checked"] > 0
    end

    test "money always carries its ISO code, and typed facts sit beside display strings", %{
      admin: admin
    } do
      bind(admin, "activity_summary", "carlito")
      run = issue!(admin, "activity_summary")

      # Read the sealed payload back through the database: sealing round-trips
      # `term_to_binary`, so the document map keeps its atom top-level keys
      # (compile-time literals) over its string-keyed contents.
      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: admin.tenant, authorize?: false)
        |> Ash.load!([:payload, :facts], tenant: admin.tenant, authorize?: false)

      rows = loaded.payload[:tables]["totals"]
      texts = rows |> Enum.flat_map(&Map.values/1)

      assert Enum.any?(texts, &String.contains?(&1, "CAD"))
      refute Enum.any?(texts, &String.contains?(&1, "$"))

      groceries = Enum.find(rows, &(&1["category"] == "Groceries"))
      assert groceries["net"] =~ "CAD"

      assert loaded.facts["fields"]["year"] == 2025

      assert %{"net" => %{"amount" => amount, "currency" => "CAD"}} =
               Enum.find(loaded.facts["tables"]["totals"], &(&1["category"] == "Groceries"))

      assert Decimal.new(amount) == Decimal.new("-25.50")
    end

    test "the snapshot holds no key material, and the key reads back sealed", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")
      run = issue!(admin, "activity_summary")

      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: admin.tenant, authorize?: false)
        |> Ash.load!(:payload_hash_key, tenant: admin.tenant, authorize?: false)

      # The key is a 32-byte secret, sealed under the scope like the payload
      # it keys: it round-trips through the sealed attribute.
      assert {:ok, key} = Base.decode64(loaded.payload_hash_key)
      assert byte_size(key) == 32

      # The snapshot itself is not sealed, so it must hold hashes and
      # references only: no key field, and nowhere the key's bytes.
      refute Map.has_key?(run.snapshot, "payload_hash_key")
      refute Jason.encode!(run.snapshot) =~ Base.encode64(key)
    end

    test "shredding the scope leaves the key and what it keyed unreadable", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")
      run = issue!(admin, "activity_summary")

      scope = Erasure.get_scope!(run.erasure_scope_id, authorize?: false)
      Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC paper test", authorize?: false)

      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: admin.tenant, authorize?: false)
        |> Ash.load!([:payload_hash_key, :payload, :facts],
          tenant: admin.tenant,
          authorize?: false
        )

      assert %Shredded{} = loaded.payload_hash_key
      assert %Shredded{} = loaded.payload
      assert %Shredded{} = loaded.facts
    end

    test "the stored snapshot names no person", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")
      run = issue!(admin, "activity_summary")

      # The column as stored, not as the resource reads it back.
      %{rows: [[stored]]} =
        AshEnterprise.Repo.query!("SELECT snapshot::text FROM paper_runs WHERE id = $1", [
          Ecto.UUID.dump!(run.id)
        ])

      refute stored =~ "actor_id"
      refute stored =~ admin.user.id
      refute stored =~ to_string(admin.user.email)
      assert Jason.decode!(stored)["snapshot"]["authority"]["tenant"] == admin.tenant
    end

    test "shredding a scope destroys the bytes no living scope still references", %{
      admin: admin
    } do
      bind(admin, "activity_summary", "carlito")

      # A second person with identical rows renders identical bytes: one
      # content-addressed version, referenced from two scopes.
      other = member!(admin, "paper-twin", [])
      PaperEntries.seed!(other)

      run_a = issue!(admin, "activity_summary")
      run_b = issue!(other, "activity_summary")

      assert run_a.erasure_scope_id != run_b.erasure_scope_id
      assert run_a.document_version_id
      assert run_a.document_version_id == run_b.document_version_id
      version_id = run_a.document_version_id
      assert [_, _] = parse_runs_for(admin, version_id)

      shred!(run_a)

      # The other scope still references the bytes: they stay, and only the
      # shredded run lets go of them.
      assert version_for(admin, run_b).id == version_id
      assert reload(admin, run_a).document_version_id == nil
      assert reload(admin, run_b).document_version_id == version_id

      shred!(run_b)

      # The last reference is gone: the bytes and their derived text go too.
      assert version_for(admin, run_b) == nil
      assert parse_runs_for(admin, version_id) == []

      assert AshEvidence.AddressedAtom
             |> Ash.Query.filter(document_version_id == ^version_id)
             |> Ash.read!(authorize?: false) == []

      assert reload(admin, run_b).document_version_id == nil
    end
  end

  describe "determinism" do
    test "same inputs twice: identical bytes and the same evidence row", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")

      run_a = issue!(admin, "activity_summary")
      run_b = issue!(admin, "activity_summary")

      assert version_for(admin, run_a).bytes == version_for(admin, run_b).bytes
      assert version_for(admin, run_a).id == version_for(admin, run_b).id
      assert run_a.output_digest == run_b.output_digest
    end

    test "a theme swap says the same things in every labelled block", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")
      carlito = issue!(admin, "activity_summary")

      binding = binding_for(admin, "activity_summary")

      Documents.rebind_paper!(
        binding,
        %{
          selection: selection(admin, "activity_summary", "caladea"),
          backend_profile_hash: profile_hash()
        },
        actor: admin.actor,
        tenant: admin.tenant
      )

      caladea = issue!(admin, "activity_summary")

      assert carlito.read_back_status == :passed
      assert caladea.read_back_status == :passed

      # The clause is present in both documents, for the same reason.
      assert [%{"key" => "hazard_note", "reason" => reason}] = carlito.clause_reasons
      assert reason =~ "Hazard"
      assert caladea.clause_reasons == carlito.clause_reasons

      # The kernel's own proof that a theme swap changes the bytes and no
      # labelled block, on the host's own PDFs: every labelled block's text
      # is identical across the two issued documents, and there were
      # labelled blocks to compare. A font may move a page break; block
      # text may not move. The clause the decision selected rides both
      # re-renders, the way it rode both issues.
      assert version_for(admin, carlito).bytes != version_for(admin, caladea).bytes

      {:ok, schema, layout, _default_theme} = Paper.definition("activity_summary")
      {:ok, payload} = Payload.build(schema, source(), title: @title, locale: :en)
      clauses = selected_clauses(admin, payload)
      assert [%{key: "hazard_note"}] = clauses

      blocks = fn theme, run ->
        {:ok, rendered} = Render.render(layout, theme, payload, clauses, Paper.limits())
        assert rendered.bytes == version_for(admin, run).bytes
        labelled_blocks(rendered, theme)
      end

      carlito_blocks = blocks.(Paper.theme("carlito"), carlito)
      caladea_blocks = blocks.(Paper.theme("caladea"), caladea)

      assert carlito_blocks != %{}
      assert carlito_blocks == caladea_blocks

      # The earlier run is pinned: the live binding says caladea, the run's
      # snapshot still says carlito.
      assert theme_hash(caladea) == Theme.hash(Paper.theme("caladea"))
      assert theme_hash(carlito) == Theme.hash(Paper.theme("carlito"))
      assert theme_hash(carlito) != theme_hash(caladea)
    end

    test "the hand-authored theme issues, reads back, and says what the plain theme says", %{
      admin: admin
    } do
      bind(admin, "activity_summary", "carlito")
      carlito = issue!(admin, "activity_summary")

      Documents.rebind_paper!(
        binding_for(admin, "activity_summary"),
        %{
          selection: selection(admin, "activity_summary", "maplestone"),
          backend_profile_hash: profile_hash()
        },
        actor: admin.actor,
        tenant: admin.tenant
      )

      maplestone = issue!(admin, "activity_summary")
      assert maplestone.read_back_status == :passed
      assert theme_hash(maplestone) == Theme.hash(Paper.theme("maplestone"))

      {:ok, schema, layout, _default_theme} = Paper.definition("activity_summary")
      {:ok, payload} = Payload.build(schema, source(), title: @title, locale: :en)
      clauses = selected_clauses(admin, payload)

      blocks = fn theme, run ->
        {:ok, rendered} = Render.render(layout, theme, payload, clauses, Paper.limits())
        assert rendered.bytes == version_for(admin, run).bytes
        labelled_blocks(rendered, theme)
      end

      plain = blocks.(Paper.theme("carlito"), carlito)
      assert plain != %{}
      assert blocks.(Paper.theme("maplestone"), maplestone) == plain
    end

    test "the plain themes keep their hashes under the kernel's optional tokens" do
      # Theme.hash/1 of each on ash_paper 5ab3222, before the optional tokens existed.
      assert Theme.hash(Paper.theme("carlito")) ==
               "fa82fea2c6677ea4c0156a563cf6376d3f536724730acf2ebecf74f2e39e34d6"

      assert Theme.hash(Paper.theme("caladea")) ==
               "13d0632caeef3dde3db2cade425929031fca8673fb741c4daef113260a5adcec"
    end

    test "a schema swap over one layout keeps the page furniture identical", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")
      bind(admin, "activity_summary_brief", "carlito")

      full = issue!(admin, "activity_summary")
      brief = issue!(admin, "activity_summary_brief")

      # The kernel's own furniture proof: the same page count and the same
      # footer runs, while what the schemas name differs.
      theme = Paper.theme("carlito")
      {full_pages, full_footer} = furniture(admin, full, theme)
      {brief_pages, brief_footer} = furniture(admin, brief, theme)

      assert full_pages == brief_pages
      assert full_footer == brief_footer
      assert full_footer != []
    end
  end

  describe "visible failures" do
    test "a subject the kind cannot read is refused, and no run row exists", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")

      assert %PaperError{reason: {:source, {:invalid_subject, :year}}} =
               unwrap(issue(admin, "activity_summary", %{}))

      assert %PaperError{reason: {:source, {:invalid_subject, :year}}} =
               unwrap(issue(admin, "activity_summary", %{"year" => "2025; anything"}))

      assert {:ok, []} = Documents.my_paper_runs(actor: admin.actor, tenant: admin.tenant)
    end

    test "a missing required value names it" do
      assert {:error, %PaperError{reason: {:payload, problems}}} =
               Issue.build_payload(ActivitySummary, %{}, Map.delete(source(), :year), @title)

      assert {:missing, "year"} in problems
    end

    test "a caller cannot put values into a document: the rows are the actor's own", %{
      admin: admin
    } do
      bind(admin, "activity_summary", "carlito")

      # Another person in the tenant, with rows of their own.
      other = member!(admin, "paper-other", [])
      PaperEntries.seed!(other, [{"x", "2025-02-02", "-999", "Groceries"}])

      run = issue!(admin, "activity_summary")

      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: admin.tenant, authorize?: false)
        |> Ash.load!(:facts, tenant: admin.tenant, authorize?: false)

      # Only the admin's four rows: the other person's entry is not theirs.
      assert Enum.sum(Enum.map(loaded.facts["tables"]["totals"], & &1["count"])) == 4

      # And the action takes no source: a caller-supplied map is refused.
      assert {:error, %Ash.Error.Invalid{}} =
               PaperRun
               |> Ash.ActionInput.for_action(
                 :issue,
                 %{document_kind: "activity_summary", source: %{year: 2025}, title: @title},
                 actor: admin.actor,
                 tenant: admin.tenant
               )
               |> Ash.run_action()
    end

    test "the payload is built in the kind's locale", %{admin: admin} do
      assert {:ok, payload} =
               Issue.payload("activity_summary", PaperEntries.subject(), @title,
                 actor: admin.actor,
                 tenant: admin.tenant
               )

      assert payload.locale == ActivitySummary.locale(PaperEntries.subject())
    end

    test "a field the schema does not name is refused at payload build, and unnamed source data never reaches a document" do
      source = Map.merge(source(), %{notes: "kept out", tags: ["a"], currencies: ["CAD"]})

      defmodule NamesANothing do
        @moduledoc false
        use AshPaper.Schema

        paper do
          key(:names_a_nothing)
          version(1)
          field :nope, :text, path: [:not_in_the_source], label: "Nope"
        end
      end

      assert {:error, [{:missing, "nope"}]} =
               Payload.build(NamesANothing, source, title: @title, locale: :en)

      {:ok, payload} = Payload.build(ActivitySummary.Schema, source, title: @title, locale: :en)

      # The source carries `notes`, `tags`, `currencies`… the schema names only
      # what an activity summary may state, so none of it can be printed.
      refute Map.has_key?(payload.fields, "notes")
      refute Map.has_key?(payload.facts["fields"], "notes")
      refute Enum.any?(payload.field_order, &(&1 in ["notes", "tags", "currencies"]))
    end

    test "a stale binding version is refused, naming the drift", %{admin: admin} do
      stale =
        selection(admin, "activity_summary", "carlito")
        |> update_in([Access.at(0), "content_hash"], fn _ -> String.duplicate("9", 64) end)

      Documents.bind_paper!(
        "activity_summary",
        Paper.binding_purpose(),
        %{selection: stale, backend_profile_hash: profile_hash()},
        actor: admin.actor,
        tenant: admin.tenant
      )

      assert %PaperError{reason: {:binding_stale, drift}} =
               unwrap(issue(admin, "activity_summary"))

      assert drift == stale

      assert {:ok, []} = Documents.my_paper_runs(actor: admin.actor, tenant: admin.tenant)
    end

    test "a Typst compile failure is a :failed run with problems recorded", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")
      {:ok, schema, _layout, theme} = Paper.definition("activity_summary")
      {:ok, payload} = Payload.build(schema, source(), title: @title, locale: :en)

      broken =
        AshPaper.Layout.compile!(
          :broken,
          1,
          "#import \"paper.typ\": *\n#show: paper-setup\n#paper-nonexistent()\n#paper-finish()"
        )

      run = start_run(admin, "activity_summary")

      assert %PaperError{reason: {:render_failed, _reason}} =
               unwrap(Issue.render(run, broken, theme, payload))

      run = get_run(admin, run.id)
      assert run.render_status == :failed
      assert [%{"detail" => _detail} | _] = run.problems
    end

    test "a read-back mismatch is a :failed read-back, recorded honestly", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")

      {run, _payload, rendered, version, theme, schema, _layout} =
        drive(admin, "activity_summary")

      {:ok, tampered_payload} =
        Payload.build(schema, %{source() | year: 2099}, title: @title, locale: :en)

      {:ok, run} =
        Issue.read_back_and_record(
          run,
          version.id,
          tampered_payload,
          rendered.bytes,
          rendered.marks,
          theme
        )

      assert run.read_back_status == :failed

      parse_run = parse_run_for(admin, version.id)
      assert parse_run.status == :failed
      assert parse_run.config["outcome"] == "failed"

      assert %{"kind" => "mismatch", "where" => "field", "key" => "year"} in parse_run.config[
               "problems"
             ]
    end

    test "a read-back that cannot measure is :unmeasured, never :passed", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")

      {run, payload, rendered, version, theme, _schema, _layout} =
        drive(admin, "activity_summary")

      {:ok, run} =
        Issue.read_back_and_record(
          run,
          version.id,
          payload,
          <<0, 1, 2, 3, "not a pdf">>,
          rendered.marks,
          theme
        )

      assert run.read_back_status == :unmeasured
      refute run.read_back_status == :passed

      parse_run = parse_run_for(admin, version.id)
      assert parse_run.status == :failed
      assert parse_run.config["outcome"] == "unmeasured"
      assert [%{"kind" => "unreadable"} | _] = parse_run.config["problems"]
    end

    test "a run whose read-back never ran stays :not_run", %{admin: admin} do
      bind(admin, "activity_summary", "carlito")

      {run, _payload, _rendered, _version, _theme, schema, _layout} =
        drive(admin, "activity_summary")

      run = get_run(admin, run.id)
      assert run.render_status == :rendered
      assert run.read_back_status == :not_run

      # And the axes refuse to move sideways or backwards: no read-back
      # without a render, no double render, no double read-back.
      {:ok, payload} = Payload.build(schema, source(), title: @title, locale: :en)

      {:ok, started} =
        Issue.start_run("activity_summary", binding_for(admin, "activity_summary").id,
          actor: admin.actor,
          tenant: admin.tenant
        )

      assert {:error, _} =
               started
               |> Ash.Changeset.for_update(:record_read_back, %{read_back_status: :passed})
               |> Ash.update(authorize?: false)

      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:record_render, %{
                 snapshot: %{a: 1},
                 output_digest: String.duplicate("a", 64),
                 payload: %{b: 1},
                 facts: %{c: 1}
               })
               |> Ash.update(authorize?: false)

      {:ok, done} =
        run
        |> Ash.Changeset.for_update(:record_read_back, %{read_back_status: :passed})
        |> Ash.update(authorize?: false)

      assert done.read_back_status == :passed

      assert {:error, _} =
               done
               |> Ash.Changeset.for_update(:record_read_back, %{read_back_status: :failed})
               |> Ash.update(authorize?: false)

      assert Verify.read_back("nope", [], payload, [], Paper.theme("carlito")).status ==
               :unmeasured
    end

    test "an unknown kind is refused before anything runs", %{admin: admin} do
      assert %PaperError{reason: {:unknown_kind, "nope"}} =
               unwrap(issue(admin, "nope"))
    end
  end

  describe "the lock" do
    test "mix paper.lock --check passes and covers the host's schemas and layout" do
      Mix.Task.rerun("paper.lock", ["--check"])

      lock = "priv/paper.lock.json" |> File.read!() |> Jason.decode!()

      for schema <- Application.fetch_env!(:ash_paper, :schemas) do
        assert Map.has_key?(lock, "schema:#{AshPaper.Schema.key(schema)}")
      end

      assert Map.has_key?(lock, "layout:letter")
    end
  end

  # ── fixtures and helpers ────────────────────────────────────────────────

  defp source, do: PaperEntries.source()

  defp profile_hash, do: AshPaper.Binding.backend_profile_hash(%{"typst" => "pinned"})

  defp selection(admin, kind, theme_name) do
    {:ok, schema, _layout, _theme} = Paper.definition(kind)
    Paper.selection(schema, Paper.layout(), Paper.theme(theme_name), admin.tenant)
  end

  # The kind's candidate wording, drafted by the admin and admitted by a
  # second pair of eyes, so every issuing test carries the clause its table
  # includes — the theme swap and the determinism checks run with wording in
  # the document, not around it.
  defp bind(admin, kind, theme_name) do
    ensure_clause(admin, kind)

    Documents.bind_paper!(
      kind,
      Paper.binding_purpose(),
      %{selection: selection(admin, kind, theme_name), backend_profile_hash: profile_hash()},
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  @clause_checker_grants [
    {PaperClause, :create, :global},
    {PaperClause, :read, :global},
    {PaperClause, :write, :global}
  ]

  defp ensure_clause(admin, kind) do
    keys = Paper.clause_keys(kind)

    if keys != [] do
      checker = member!(admin, "paper-clerk", @clause_checker_grants)

      for key <- keys do
        ClauseTables.publish!(admin.tenant, key)

        clause =
          Documents.draft_paper_clause!(
            key,
            :en,
            %{runs: [%{"kind" => "text", "value" => "Hazard follow-up explained."}]},
            actor: admin.actor,
            tenant: admin.tenant
          )

        clause
        |> Documents.measure_paper_clause_impact!(actor: checker.actor, tenant: admin.tenant)
        |> Documents.admit_paper_clause!(actor: checker.actor, tenant: admin.tenant)
      end
    end
  end

  defp binding_for(admin, kind) do
    Documents.get_paper_binding_by_selector!(Paper.binding_selector(kind),
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  # The clause maps an issue renders with: the admitted kernel clauses for the
  # kind's candidate keys, resolved into the payload's locale.
  defp selected_clauses(admin, payload) do
    clauses =
      Paper.latest_admitted_clauses(Paper.clause_keys("activity_summary"), admin.tenant)
      |> Enum.map(&PaperClause.to_kernel/1)

    assert {:ok, resolved} =
             AshPaper.Clause.resolve(clauses, Enum.map(clauses, & &1.key), payload)

    resolved
  end

  # The rows' Hazard entry makes the activity_summary requirement ask whether
  # it was followed up; these tests are about rendering, so it is answered
  # first (`AshEnterprise.Documents.PaperInterviewTest` covers the asking).
  defp issue(admin, kind, subject \\ PaperEntries.subject(), title \\ @title) do
    PaperFacts.answer_all!(admin, kind, subject, title)

    Documents.issue_paper_run(kind, subject, title,
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp issue!(admin, kind) do
    assert {:ok, run} = issue(admin, kind)
    run
  end

  defp unwrap({:error, %PaperError{} = error}), do: error

  defp unwrap({:error, class}) do
    assert [inner] = Enum.filter(class.errors, &match?(%PaperError{}, &1))
    inner
  end

  # The pipeline minus payload build and binding verify: a run recorded as
  # rendered, with its bytes stored and nothing read back yet.
  defp drive(admin, kind) do
    {:ok, schema, layout, theme} = Paper.definition(kind)
    {:ok, payload} = Payload.build(schema, source(), title: @title, locale: :en)
    run = start_run(admin, kind)

    {:ok, rendered} = Render.render(layout, theme, payload, [], Paper.limits())
    {:ok, version} = Issue.ingest(admin.tenant, rendered.bytes)
    {:ok, run} = Issue.record_render(run, schema, layout, theme, payload, rendered)

    {run, payload, rendered, version, theme, schema, layout}
  end

  defp shred!(run) do
    scope = Erasure.get_scope!(run.erasure_scope_id, authorize?: false)
    Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC paper test", authorize?: false)
  end

  defp reload(admin, run),
    do: Documents.get_paper_run!(run.id, tenant: admin.tenant, authorize?: false)

  defp start_run(admin, kind) do
    {:ok, run} =
      Issue.start_run(kind, binding_for(admin, kind).id, actor: admin.actor, tenant: admin.tenant)

    run
  end

  defp get_run(admin, id) do
    assert {:ok, runs} = Documents.my_paper_runs(actor: admin.actor, tenant: admin.tenant)
    Enum.find(runs, &(&1.id == id))
  end

  defp version_for(admin, run) do
    AshEvidence.DocumentVersion
    |> Ash.Query.filter(sha256 == ^run.output_digest)
    |> Ash.read_one!(tenant: admin.tenant, authorize?: false)
  end

  # Each run's read-back is one parse run of the version it rendered.
  defp parse_runs_for(admin, version_id) do
    AshEvidence.ParseRun
    |> Ash.Query.filter(document_version_id == ^version_id)
    |> Ash.read!(tenant: admin.tenant, authorize?: false)
  end

  defp parse_run_for(admin, version_id) do
    AshEvidence.ParseRun
    |> Ash.Query.filter(
      document_version_id == ^version_id and instrument == "ash_paper.read_back"
    )
    |> Ash.read_one!(tenant: admin.tenant, authorize?: false)
  end

  # The footer runs a PDF carries in its bottom margin, with its page count
  # (`AshPaper.Verify` compares only the body region; this is its complement).
  defp furniture(admin, run, theme) do
    {:ok, runs, heights} = Pdf.Text.runs(version_for(admin, run).bytes)

    footer =
      for r <- runs, r.top > heights[r.page] - theme.margin_y do
        {r.page, round(r.x), round(r.top), r.text}
      end

    {map_size(heights), footer}
  end

  # Every labelled block's squashed text, read out of an issued PDF the way
  # `AshPaper.Verify` reads one: `Pdf.Text` runs inside the body margins,
  # each block's bounds from its render marks, the runs joined in order.
  defp labelled_blocks(rendered, theme) do
    {:ok, runs, heights} = Pdf.Text.runs(rendered.bytes)

    body =
      Enum.filter(
        runs,
        &(&1.top >= theme.margin_y - 1 and &1.top <= heights[&1.page] - theme.margin_y + 1)
      )

    indexed = Enum.with_index(rendered.marks)

    for {mark, index} = start <- indexed,
        mark["value"]["edge"] == "start",
        into: %{} do
      {stop, tolerance} =
        if mark["value"]["kind"] == "row" do
          {Enum.find(indexed, fn {_m, i} -> i == index + 1 end), -1}
        else
          {Enum.find(indexed, fn {m, _i} ->
             m["value"]["kind"] == mark["value"]["kind"] and
               m["value"]["key"] == mark["value"]["key"] and
               m["value"]["edge"] == "end"
           end), 0.5}
        end

      {label(mark), block_text(body, start, stop, tolerance)}
    end
  end

  defp label(mark), do: "#{mark["value"]["kind"]}:#{mark["value"]["key"]}"

  # Mirrors `AshPaper.Verify`'s private find/position/collect: the body runs
  # between the block's start and stop marks, squashed.
  defp block_text(runs, {start, _index}, {stop, _stop_index}, tolerance) do
    {first_page, first_y} = {start["page"], start["y"]}
    {last_page, last_y} = {stop["page"], stop["y"]}

    runs
    |> Enum.filter(fn run ->
      after_start = run.page > first_page or (run.page == first_page and run.top >= first_y - 3)

      before_end =
        run.page < last_page or (run.page == last_page and run.top <= last_y + tolerance)

      after_start and before_end
    end)
    |> Enum.map_join("", & &1.text)
    |> String.replace(~r/[\s\x{A0}]+/u, "")
  end

  defp theme_hash(run) do
    definition =
      Enum.find(run.snapshot["snapshot"]["definitions"], &(&1["kind"] == "theme"))

    definition["content_hash"]
  end
end

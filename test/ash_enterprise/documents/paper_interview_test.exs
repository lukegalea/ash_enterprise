defmodule AshEnterprise.Documents.PaperInterviewTest do
  @moduledoc """
  R1 and R8: a document blocked by a requirement says exactly which facts it is
  missing, takes the answers through a person's own action, and clears when
  they are answered; the next document in the same scope is not asked again
  unless the answer is stale, expired, below person grade or for another year.
  The kind is the SYNTHETIC `activity_summary` and its requirement
  `HazardFollowUp`; the rows are seeded entries the kind reads back as the
  person — nothing here is anyone's data.
  """

  use AshEnterprise.DataCase, async: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Actions.Issue
  alias AshEnterprise.Documents.Paper.Interview
  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.Test.Paper.ActivitySummary
  alias AshEnterprise.Test.PaperEntries
  alias AshEnterpriseWeb.A2ui.PaperQuestionsUI
  alias AshJudgments.Facts.Materialiser

  @moduletag :evidence

  @title "Activity summary"
  @predicate "hazard_follow_up_confirmed"
  @rule "paper.activity_summary.hazard_follow_up"

  setup do
    admin = tenant!()
    bind(admin)
    PaperEntries.seed!(admin, Enum.flat_map([year(), year() - 1, year() - 2], &hazard_rows/1))
    {:ok, admin: admin}
  end

  describe "asking, answering, issuing" do
    test "a hazard year is blocked with exactly one missing fact; answered, it issues", %{
      admin: admin
    } do
      assert %Paper.Error{reason: {:missing_facts, [entry]}} = unwrap(issue(admin))

      assert entry["predicate"] == @predicate
      assert entry["subject"] == "activity_year"
      assert entry["rule"] == @rule
      assert entry["message"] =~ "follow-up confirmed"
      assert [evidence] = entry["evidence"]
      assert evidence =~ "follow-up on record"
      assert entry["question"] =~ "followed up"
      assert entry["reason"] == "no_fact"
      assert entry["scope"] == %{"organization" => admin.tenant, "year" => year()}

      # Recorded on the run like every other block: a failed run, no bytes.
      run = latest_run(admin)
      assert run.render_status == :failed
      assert run.output_digest == nil

      assert [%{"kind" => "missing_fact", "predicate" => @predicate, "rule" => @rule}] =
               run.problems

      assert {:ok, answer} = answer(admin, run, true)
      assert answer.owner_id == admin.actor.id
      assert answer.scope == %{"organization" => admin.tenant, "year" => year()}
      assert answer.subject_state_digest == entry["digest"]
      assert answer.valid_until == DateTime.new!(Date.new!(year() + 2, 1, 1), ~T[00:00:00.000000])

      # The answer is the fact's admission, at person grade.
      assert {:in, fact} = fact_status(admin, year(), entry["digest"])
      assert fact.admission_grade == :person
      assert fact.admission_id == answer.id

      assert {:ok, issued} = issue(admin)
      assert issued.render_status == :rendered
      assert issued.read_back_status == :passed
    end

    test "the same scope issues again without asking, and a draft is not asked either", %{
      admin: admin
    } do
      {:error, _blocked} = issue(admin)
      {:ok, _answer} = answer(admin, latest_run(admin), true)

      assert {:ok, %{render_status: :rendered}} = issue(admin)
      assert {:ok, %{render_status: :rendered}} = issue(admin)

      assert {:ok, draft} =
               Documents.draft_paper_run(
                 "activity_summary",
                 PaperEntries.subject(year()),
                 @title,
                 as(admin)
               )

      assert draft.check_status == :correct
      assert {:ok, [_one]} = Documents.my_paper_answers(as(admin))
    end

    test "a year with no hazard never asks", %{admin: admin} do
      member = member!(admin, "paper-groceries", [])

      PaperEntries.seed!(member, [
        {"a", "#{year()}-01-02", "-20", "Groceries"},
        {"b", "#{year()}-03-04", "-5.50", "Groceries"}
      ])

      assert {:ok, run} = issue(member)
      assert run.render_status == :rendered
      assert run.problems == []
      assert {:ok, []} = Documents.my_paper_answers(as(member))
      assert {:ok, []} = Documents.open_paper_questions(as(member))
    end

    test "a draft is gated the same way: blocked, recorded, and no draft proposed", %{
      admin: admin
    } do
      assert %Paper.Error{reason: {:missing_facts, [%{"predicate" => @predicate}]}} =
               unwrap(
                 Documents.draft_paper_run(
                   "activity_summary",
                   PaperEntries.subject(year()),
                   @title,
                   as(admin)
                 )
               )

      run = latest_run(admin)
      assert run.stage == :draft
      assert run.render_status == :failed
      assert {:ok, []} = Documents.list_paper_drafts(as(admin))
    end
  end

  describe "asked again" do
    test "a stale answer: the rows changed since it was given", %{admin: admin} do
      {:error, _blocked} = issue(admin)
      {:ok, _answer} = answer(admin, latest_run(admin), true)

      PaperEntries.change!(admin, "Hazard", %{amount: "-60"})

      assert %Paper.Error{reason: {:missing_facts, [entry]}} = unwrap(issue(admin))

      assert entry["reason"] == "stale"
      assert [%{"kind" => "missing_fact", "reason" => "stale"}] = latest_run(admin).problems
      assert {:unknown, :stale} = fact_status(admin, year(), entry["digest"])

      # The rows as they were still read the answer.
      PaperEntries.change!(admin, "Hazard", %{amount: "-40"})
      assert {:ok, %{render_status: :rendered}} = issue(admin)
    end

    test "an expired answer: given in time, read after its valid_until", %{admin: admin} do
      assert %Paper.Error{reason: {:missing_facts, [entry]}} = unwrap(issue(admin))

      # A person's answer for this scope and rows whose validity has run out,
      # as one given for the year and read after the end of the next would be.
      assert {:ok, :materialised} =
               Materialiser.materialise_verdict(
                 %{
                   subject: Interview.fact_subject(admin.tenant),
                   predicate: @predicate,
                   value: true,
                   holds: true,
                   scope: entry["scope"],
                   subject_state_digest: entry["digest"],
                   valid_until: DateTime.add(DateTime.utc_now(), -60, :second)
                 },
                 resource: Fact
               )

      assert {:unknown, :expired} = fact_status(admin, year(), entry["digest"])
      assert %Paper.Error{reason: {:missing_facts, [again]}} = unwrap(issue(admin))
      assert again["reason"] == "expired"
      assert [%{"kind" => "missing_fact", "reason" => "expired"}] = latest_run(admin).problems
    end

    test "an answer for a year whose validity has already run out is refused", %{admin: admin} do
      # An answer holds until the end of the following year, so one for three
      # years back would be expired the moment it was written.
      old = year() - 2
      assert %Paper.Error{reason: {:missing_facts, [_entry]}} = unwrap(issue(admin, old))

      assert {:error, %Ash.Error.Invalid{} = error} = answer(admin, latest_run(admin), true)
      assert Exception.message(error) =~ "can no longer be answered in this scope"
      assert {:ok, []} = Documents.my_paper_answers(as(admin))
      assert {:unknown, :no_fact} = fact_status(admin, old, nil)
    end

    test "another year is asked again", %{admin: admin} do
      {:error, _blocked} = issue(admin, year())
      {:ok, _answer} = answer(admin, latest_run(admin), true)

      assert %Paper.Error{reason: {:missing_facts, [entry]}} =
               unwrap(issue(admin, year() - 1))

      assert entry["reason"] == "no_fact"
      assert entry["scope"] == %{"organization" => admin.tenant, "year" => year() - 1}
      assert [%{"kind" => "missing_fact", "reason" => "no_fact"}] = latest_run(admin).problems
    end

    test "an answer below person grade does not satisfy the rule", %{admin: admin} do
      assert %Paper.Error{reason: {:missing_facts, [entry]}} = unwrap(issue(admin))

      # Automation's admission, same scope and digest: a grant-grade fact.
      assert {:ok, :materialised} =
               Materialiser.materialise(
                 %{
                   result: :admitted,
                   grade: :grant,
                   subject: Interview.fact_subject(admin.tenant),
                   predicate: @predicate,
                   value: true,
                   holds: true,
                   scope: entry["scope"],
                   subject_state_digest: entry["digest"],
                   valid_until: Interview.valid_until("activity_summary", %{"year" => year()})
                 },
                 resource: Fact
               )

      assert %Paper.Error{reason: {:missing_facts, [again]}} = unwrap(issue(admin))
      assert again["reason"] == "below_grade"
      assert [%{"kind" => "missing_fact", "reason" => "below_grade"}] = latest_run(admin).problems
    end
  end

  describe "refusals" do
    test "a no is a rule that fires: requirement_failed, not missing", %{admin: admin} do
      {:error, _blocked} = issue(admin)
      {:ok, _answer} = answer(admin, latest_run(admin), false)

      assert %Paper.Error{reason: {:requirement_failed, [failure]}} = unwrap(issue(admin))
      assert failure["rule"] == @rule
      assert failure["status"] == "noncompliant"
      assert failure["severity"] == "high"
      assert failure["gap"] == "paper.hazard_follow_up"

      run = latest_run(admin)
      assert run.render_status == :failed
      assert [%{"kind" => "requirement_failed", "rule" => @rule}] = run.problems
      refute Enum.any?(run.problems, &(&1["kind"] == "missing_fact"))
    end

    test "the answer refuses a predicate the requirement does not declare or does not ask", %{
      admin: admin
    } do
      {:error, _blocked} = issue(admin)
      run = latest_run(admin)

      assert {:error, %Ash.Error.Invalid{} = undeclared} =
               answer(admin, run, true, "follow_up_scanned")

      assert Exception.message(undeclared) =~
               "is not a fact the activity_summary requirement declares"

      assert {:error, %Ash.Error.Invalid{} = ground} =
               answer(admin, run, true, "hazard_category_present")

      assert Exception.message(ground) =~ "decided by the document"

      assert {:ok, []} = Documents.my_paper_answers(as(admin))
      assert {:unknown, :no_fact} = fact_status(admin, year(), nil)
    end

    test "a person cannot answer for another organization", %{admin: admin} do
      {:error, _blocked} = issue(admin)
      run = latest_run(admin)
      outsider = tenant!()

      # In their own organization, the run is not theirs to find.
      assert {:error, %Ash.Error.Invalid{} = error} = answer(outsider, run, true)
      assert Exception.message(error) =~ "is not one of your runs"

      # Naming the other organization as the tenant reaches nothing either.
      assert {:error, _refused} =
               Documents.answer_paper_question(
                 %{run_id: run.id, predicate: @predicate, holds: true},
                 actor: outsider.actor,
                 tenant: admin.tenant
               )

      # Nor can another member of the same organization answer on the admin's run.
      member = member!(admin, "paper-member-#{System.unique_integer([:positive])}", [])
      assert {:error, _not_theirs} = answer(member, run, true)

      assert {:unknown, :no_fact} = fact_status(admin, year(), nil)
      assert %Paper.Error{reason: {:missing_facts, _still}} = unwrap(issue(admin))
    end
  end

  describe "never read as a pass" do
    test "a requirement that cannot be evaluated blocks; it is not satisfied", %{admin: admin} do
      subject = Interview.subject(ActivitySummary, payload(admin), admin.tenant)

      # A fact outside the requirement's schema fails the evaluation itself.
      broken = %{subject | ground: [{"activity_year", :not_in_the_schema, true} | subject.ground]}

      assert {:blocked, {:requirement_error, detail}} = Interview.evaluate(broken)
      assert is_binary(detail)
    end

    test "an answer the facts table cannot vouch for emits nothing, so the rule stays unknown",
         %{admin: admin} do
      subject = Interview.subject(ActivitySummary, payload(admin), admin.tenant)
      name = String.to_existing_atom(@predicate)

      for reason <- [:no_fact, :stale, :expired, :below_grade, :error] do
        facts = Interview.facts(subject, asked: %{name => {:unknown, reason}})
        refute Enum.any?(facts, &match?({_subject, ^name, _value}, &1))
      end

      assert {"activity_year", name, true} in Interview.facts(subject,
               asked: %{name => {:in, :fact}}
             )

      assert {"activity_year", name, false} in Interview.facts(subject,
               asked: %{name => {:out, :fact}}
             )

      assert {:blocked, {:missing_facts, [%{"reason" => "no_fact"}]}} =
               Interview.evaluate(subject)
    end
  end

  describe "the questions surface" do
    test "lists the missing fact with its rule's words, and answering clears it", %{
      admin: admin
    } do
      {:error, _blocked} = issue(admin)
      run = latest_run(admin)

      assert [row] = rows(admin)
      assert row["id"] == "#{run.id}/#{@predicate}"
      assert row["question"] =~ "followed up"
      assert row["message"] =~ "follow-up confirmed"
      assert row["evidence"] =~ "follow-up on record"
      assert row["reason"] == "Not answered yet"
      assert row["about"] == to_string(year())

      # Someone else sees none of it.
      assert rows(tenant!()) == []

      assert {:ok, _messages} = invoke(admin, "confirm", row["id"])
      assert rows(admin) == []
      assert {:ok, [_answer]} = Documents.my_paper_answers(as(admin))

      assert {:ok, %{render_status: :rendered}} = issue(admin)
    end

    test "the open questions are a page, not the whole list", %{admin: admin} do
      {:error, _blocked} = issue(admin, year())
      {:error, _blocked} = issue(admin, year() - 1)

      assert {:ok, [_, _] = both} = Documents.open_paper_questions(as(admin))

      assert {:ok, [first]} =
               Documents.open_paper_questions(as(admin) ++ [query: [limit: 1]])

      assert {:ok, [second]} =
               Documents.open_paper_questions(as(admin) ++ [query: [limit: 1, offset: 1]])

      assert [first, second] == both
    end

    test "a refused answer leaves the question listed", %{admin: admin} do
      {:error, _blocked} = issue(admin)
      [row] = rows(admin)

      assert {:error, _messages} =
               invoke(admin, "confirm", "#{Ash.UUID.generate()}/#{@predicate}")

      assert [^row] = rows(admin)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp as(person), do: [actor: person.actor, tenant: person.tenant]

  defp issue(person, year \\ year()),
    do:
      Documents.issue_paper_run(
        "activity_summary",
        PaperEntries.subject(year),
        @title,
        as(person)
      )

  defp answer(person, run, holds, predicate \\ @predicate) do
    Documents.answer_paper_question(
      %{run_id: run.id, predicate: predicate, holds: holds},
      as(person)
    )
  end

  defp payload(person) do
    {:ok, payload} =
      Issue.payload("activity_summary", PaperEntries.subject(year()), @title, as(person))

    payload
  end

  defp latest_run(person) do
    {:ok, [run | _older]} = Documents.my_paper_runs(as(person))
    run
  end

  # The answer as the interview reads it: person grade, in the year's scope,
  # against `digest` (nil reads any digest as current).
  defp fact_status(admin, year, digest) do
    subject = Interview.fact_subject(admin.tenant)

    AshJudgments.Query.status(Fact, subject, @predicate,
      scope: Interview.scope(admin.tenant, %{"year" => year}),
      min_grade: :person,
      current_digests: if(digest, do: %{subject => digest}, else: %{})
    )
  end

  defp rows(person) do
    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(PaperQuestionsUI, actor: person.actor, tenant: person.tenant)

    value["records"]
  end

  defp invoke(person, action, record_id) do
    AshA2ui.ActionHandler.handle(
      PaperQuestionsUI,
      AshEnterprise.A2uiMessage.ash_action(PaperQuestionsUI, "invoke", %{
        "action" => action,
        "recordId" => record_id,
        "component" => "table"
      }),
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp unwrap({:error, %Paper.Error{} = error}), do: error

  defp unwrap({:error, class}) do
    assert [inner] = Enum.filter(class.errors, &match?(%Paper.Error{}, &1))
    inner
  end

  # The binding pins no clause wording, so no clause table is consulted: the
  # requirement is the only thing between these rows and the render.
  defp bind(admin) do
    {:ok, schema, _layout, _theme} = Paper.definition("activity_summary")

    Documents.bind_paper!(
      "activity_summary",
      Paper.binding_purpose(),
      %{
        selection: Paper.selection(schema, Paper.layout(), Paper.theme("carlito"), admin.tenant),
        backend_profile_hash: AshPaper.Binding.backend_profile_hash(%{"typst" => "pinned"})
      },
      as(admin)
    )
  end

  # The year the rows are about: last year, so an answer given today is
  # within its validity (the end of the following year) whenever this runs.
  defp year, do: Date.utc_today().year - 1

  # Synthetic: CAD rows in `year`, one of them a Hazard.
  defp hazard_rows(year) do
    [
      {"a#{year}", "#{year}-01-02", "-20", "Groceries"},
      {"b#{year}", "#{year}-07-15", "-40", "Hazard"}
    ]
  end
end

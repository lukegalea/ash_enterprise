defmodule AshEnterprise.SystemOne.JudgedFieldsTest do
  @moduledoc """
  S1-53 (PL-1): the derived judgment fields on a real resource —
  `AshEnterprise.Canonical.Task`'s declared `:task_actionable` question.

  - AC-1: the derived field is never a two-valued boolean; unknown, stale,
    expired and below-grade all read `nil` with the matching status and
    reason, in agreement with `AshJudgments.Query.status/4`.
  - AC-2: filtering tasks by the judged predicate is one SQL query and
    zero instrument calls (telemetry-asserted).
  - AC-3: retitling a task turns its fact stale and enqueues the reassess
    trigger; changing the due date or the status enqueues nothing.
  - AC-4/AC-5 ride AC-2's fixture: negation returns only admitted-out
    tasks, the unassessed are on neither side, and the filter never
    returns a task the reader cannot read.

  Every task title is SYNTHETIC.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  require Ash.Query

  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.JudgedFields
  alias AshEnterprise.Test.DailyFixtures
  alias AshJudgments.Facts.Materialiser

  @worker Task.ReassessJudgmentsWorker

  setup do
    Correlation.start_new()
    ctx = DailyFixtures.tenant!()
    [field] = JudgedFields.fields(Task)
    Map.put(ctx, :field, field)
  end

  ## Fixtures

  defp task!(ctx, title, attrs \\ %{}) do
    Task
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(
        %{
          title: title,
          status: :open,
          source: "slack",
          external_system: "slack",
          external_id: "SYNTHETIC-#{System.unique_integer([:positive])}",
          owner_id: ctx.user.id,
          owner_type: :user,
          owning_user_id: ctx.user.id,
          owning_business_unit_id: ctx.user.owning_business_unit_id
        },
        attrs
      ),
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp reupsert!(ctx, task, attrs) do
    task!(
      ctx,
      Map.get(attrs, :title, task.title),
      Map.merge(
        %{external_id: task.external_id, due_at: task.due_at, status: task.status},
        Map.delete(attrs, :title)
      )
    )
  end

  defp digest(task, field), do: task.judgment_digests[field.question_id]

  defp other_digest(field),
    do: JudgedFields.state_digest(Task, field, %{"title" => "SYNTHETIC something else"})

  defp admit!(task, field, holds, opts \\ []) do
    decision = %{
      result: :admitted,
      subject: JudgedFields.subject(Task, task.id),
      predicate: field.question_id,
      value: holds,
      holds: holds,
      grade: Keyword.get(opts, :grade, :grant),
      scope: Keyword.get(opts, :scope),
      subject_state_digest: Keyword.get(opts, :digest, digest(task, field)),
      valid_until: Keyword.get(opts, :valid_until),
      # The materialiser's default instant is now truncated to the second;
      # a fixture fact opens a minute earlier so a revision in the same
      # second (the reassess test) splits inside the period, not at its start.
      effective_at: DateTime.add(DateTime.utc_now(), -60, :second),
      id: Ash.UUID.generate()
    }

    assert {:ok, :materialised} = Materialiser.materialise(decision)
  end

  defp fields!(task, ctx, args \\ %{}) do
    loaded =
      Ash.load!(
        task,
        [
          task_actionable: args,
          task_actionable_status: args,
          task_actionable_reason: args
        ],
        tenant: ctx.tenant,
        authorize?: false
      )

    {loaded.task_actionable, loaded.task_actionable_status, loaded.task_actionable_reason}
  end

  ## The generated surface

  describe "the registry drives the fields" do
    test "one tri-state, status and reason field per declared question, public and nullable",
         %{field: field} do
      tri = Ash.Resource.Info.calculation(Task, field.tri_state)
      status = Ash.Resource.Info.calculation(Task, field.status)
      reason = Ash.Resource.Info.calculation(Task, field.reason)

      assert tri.public? and status.public? and reason.public?
      assert tri.allow_nil?
      assert tri.type == Ash.Type.Boolean
      assert status.type == Ash.Type.Atom

      assert status.constraints[:one_of] ==
               [:admitted_true, :admitted_false, :review, :not_assessed, :stale]

      assert Enum.map(tri.arguments, & &1.name) == [:min_grade, :scope]
      assert field.projection == ["title"]
    end

    test "the API layers' input path filters and sorts by the fields", ctx do
      in_task = task!(ctx, "SYNTHETIC renew the parking permit")
      admit!(in_task, ctx.field, true)
      _unknown = task!(ctx, "SYNTHETIC stuff")

      # `filter_input`/`sort_input` are the public-field paths AshJsonApi,
      # AshGraphql and AshPhoenix filter forms all go through.
      query =
        Task
        |> Ash.Query.filter_input(%{"task_actionable" => %{"eq" => true}})
        |> Ash.Query.sort_input("-task_actionable_status")

      assert [found] = Ash.read!(query, actor: ctx.actor, tenant: ctx.tenant)
      assert found.id == in_task.id
    end
  end

  ## AC-1

  describe "AC-1: never a two-valued boolean" do
    test "unknown, stale, expired and below-grade all read nil with the matching status", ctx do
      field = ctx.field
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      cases = [
        {:no_fact, [], %{}, {nil, :not_assessed, :no_fact}},
        {:in, [holds: true], %{}, {true, :admitted_true, nil}},
        {:out, [holds: false], %{}, {false, :admitted_false, nil}},
        {:stale, [holds: true, digest: other_digest(field)], %{}, {nil, :stale, :stale}},
        {:expired, [holds: true, valid_until: past], %{}, {nil, :stale, :expired}},
        {:below_grade, [holds: true], %{min_grade: :person}, {nil, :not_assessed, :below_grade}},
        {:person_floor_met, [holds: false, grade: :person], %{min_grade: :person},
         {false, :admitted_false, nil}},
        {:other_scope, [holds: true, scope: %{"requirement_set" => "a"}],
         %{scope: %{"requirement_set" => "b"}}, {nil, :not_assessed, :no_fact}},
        {:narrower_scope, [holds: true, scope: %{"requirement_set" => "a", "site" => "1"}],
         %{scope: %{"requirement_set" => "a"}}, {true, :admitted_true, nil}},
        {:scoped_fact_unscoped_read, [holds: true, scope: %{"requirement_set" => "a"}], %{},
         {nil, :not_assessed, :no_fact}}
      ]

      for {label, fact, args, expected} <- cases do
        task = task!(ctx, "SYNTHETIC task #{label}")

        if fact != [] do
          admit!(task, field, Keyword.fetch!(fact, :holds), Keyword.delete(fact, :holds))
        end

        read = fields!(task, ctx, args)
        assert read == expected, "#{label}: expected #{inspect(expected)}, read #{inspect(read)}"

        {tri, _status, reason} = read
        assert tri in [true, false, nil]
        if is_nil(tri), do: assert(reason in JudgedFields.reasons())

        # The same decision AshJudgments.Query makes, one subject at a time.
        assert query_status(task, field, args) == {tri, reason},
               "#{label}: the SQL field and AshJudgments.Query.status/4 disagree"
      end
    end
  end

  defp query_status(task, field, args) do
    subject = JudgedFields.subject(Task, task.id)

    opts =
      [current_digests: %{subject => digest(task, field)}, min_grade: args[:min_grade] || :grant]
      |> Keyword.put(:scope, args[:scope])

    case AshJudgments.Query.status(Fact, subject, field.question_id, opts) do
      {:in, _fact} -> {true, nil}
      {:out, _fact} -> {false, nil}
      {:unknown, reason} -> {nil, reason}
    end
  end

  ## AC-2 (with AC-4 and AC-5 on the same fixture)

  describe "AC-2: a judged filter is one SQL query and zero instrument calls" do
    setup ctx do
      in_task = task!(ctx, "SYNTHETIC file the expense report")
      out_task = task!(ctx, "SYNTHETIC misc")
      unassessed = task!(ctx, "SYNTHETIC think about things")
      admit!(in_task, ctx.field, true)
      admit!(out_task, ctx.field, false)
      %{in_task: in_task, out_task: out_task, unassessed: unassessed}
    end

    test "filtering by the predicate reads in one query, with no instrument in the path", ctx do
      {result, events} =
        capture_events(fn ->
          Task
          |> Ash.Query.filter(task_actionable == true)
          |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)
        end)

      assert Enum.map(result, & &1.id) == [ctx.in_task.id]
      assert Enum.count(events, &(&1 == :sql)) == 1
      refute :instrument in events
    end

    test "AC-4: negation is the admitted-out side only; the unassessed are on neither side",
         ctx do
      read = fn query -> query |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant) |> ids() end

      inside = read.(Ash.Query.filter(Task, task_actionable))
      outside = read.(Ash.Query.filter(Task, not task_actionable))
      unknown = read.(Ash.Query.filter(Task, task_actionable_status == :not_assessed))

      assert inside == [ctx.in_task.id]
      assert outside == [ctx.out_task.id]
      assert unknown == [ctx.unassessed.id]
      assert length(inside) + length(outside) + length(unknown) == 3
    end

    test "AC-5: a judged filter never returns a task the reader cannot read", ctx do
      grantless = DailyFixtures.member!(ctx, "SYNTHETIC no grants", [])

      assert [] ==
               Task
               |> Ash.Query.filter(task_actionable == true)
               |> Ash.read!(actor: grantless.actor, tenant: ctx.tenant)
    end
  end

  defp ids(records), do: records |> Enum.map(& &1.id) |> Enum.sort()

  # Repo queries and instrument calls observed while `fun` runs, in order.
  defp capture_events(fun) do
    test_pid = self()
    handler = "judged-fields-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_enterprise, :repo, :query],
        [:ash_judgments, :judgment, :start],
        [:req_llm, :request, :start]
      ],
      fn
        # Only this test's own queries: the app's background processes share
        # the repo. Instrument calls are counted from anywhere.
        [:ash_enterprise, :repo, :query], _measurements, _meta, _config ->
          if self() == test_pid, do: send(test_pid, {:judged_fields_event, :sql})

        _event, _measurements, _meta, _config ->
          send(test_pid, {:judged_fields_event, :instrument})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_events([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_events(acc) do
    receive do
      {:judged_fields_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## AC-3

  describe "AC-3: a projection change goes stale and enqueues; an unrelated change does not" do
    setup ctx do
      task = task!(ctx, "SYNTHETIC send the board deck")
      admit!(task, ctx.field, true)
      %{task: task}
    end

    test "changing the due date or the status enqueues nothing and stays admitted", ctx do
      due = DateTime.add(DateTime.utc_now(), 86_400, :second)
      redated = reupsert!(ctx, ctx.task, %{due_at: due})
      assert redated.id == ctx.task.id
      assert digest(redated, ctx.field) == digest(ctx.task, ctx.field)

      completed =
        redated
        |> Ash.Changeset.for_update(:complete, %{}, tenant: ctx.tenant, authorize?: false)
        |> Ash.update!()

      assert completed.status == :done
      refute_enqueued(worker: @worker)
      assert {true, :admitted_true, nil} == fields!(completed, ctx)
    end

    test "retitling turns the fact stale and enqueues the reassess trigger", ctx do
      retitled = reupsert!(ctx, ctx.task, %{title: "SYNTHETIC send the revised board deck"})
      assert retitled.id == ctx.task.id
      refute digest(retitled, ctx.field) == digest(ctx.task, ctx.field)

      assert {nil, :stale, :stale} == fields!(retitled, ctx)

      assert_enqueued(
        worker: @worker,
        queue: :system_one,
        args: %{"primary_key" => %{"id" => retitled.id}}
      )

      # A second retitle before the job runs is the same job, not another.
      reupsert!(ctx, retitled, %{title: "SYNTHETIC send the final board deck"})
      assert length(all_enqueued(worker: @worker)) == 1
    end

    test "a task with no fact enqueues nothing when retitled", ctx do
      task = task!(ctx, "SYNTHETIC unassessed")
      reupsert!(ctx, task, %{title: "SYNTHETIC unassessed, retitled"})
      refute_enqueued(worker: @worker)
    end
  end

  ## The reassess job

  describe "the reassess job" do
    setup ctx do
      previous = Application.get_env(:ash_enterprise, JudgedFields)
      on_exit(fn -> restore_env(previous) end)

      task = task!(ctx, "SYNTHETIC book the venue")
      admit!(task, ctx.field, true)
      retitled = reupsert!(ctx, task, %{title: "SYNTHETIC book the larger venue"})
      %{task: retitled}
    end

    test "selects the stale fact through the assess path and hands it to the assessor", ctx do
      test_pid = self()

      Application.put_env(:ash_enterprise, JudgedFields,
        assessor: {__MODULE__, :capture_assessment, [test_pid]}
      )

      assert %{success: 1} = Oban.drain_queue(queue: :system_one, with_safety: false)

      assert_received {:assessed, request}
      assert request.field.name == :task_actionable
      assert request.reason == :stale
      assert request.state == %{"title" => "SYNTHETIC book the larger venue"}
      assert request.digest == digest(ctx.task, ctx.field)
      assert request.subject == JudgedFields.subject(Task, ctx.task.id)
      refute_received {:assessed, _}
    end

    # An `admit` band over the existing fact: a real revision. The
    # materialiser splits the stale fact's period, so its id carries two
    # versions (the `(id, valid_at)` exclusion allows that, one per instant).
    test "the default assessor judges, records and bands the stale fact", ctx do
      # The profile resolves its host at call time; the fake transport means
      # nothing is ever sent there.
      System.put_env("OLLAYA_BASE_URL", "http://127.0.0.1:11435")
      System.put_env("OLLAYA_API_KEY", "local-test-only")

      on_exit(fn ->
        System.delete_env("OLLAYA_BASE_URL")
        System.delete_env("OLLAYA_API_KEY")
      end)

      evaluation = %{
        band_table: %{
          "definition_key" => "judgments_band_canonical_tasks",
          "definition_version" => "1",
          "content_hash" => "sha256:" <> String.duplicate("a", 64),
          "definition_id" => Ash.UUID.generate(),
          "tenant_fork" => nil
        },
        outputs: %{"band" => "admit", "fact_value" => false, "reason_code" => "retitled_unclear"},
        matched_rule_ids: ["DecisionRule_1"],
        decision_evaluation_id: Ash.UUID.generate()
      }

      Application.put_env(:ash_enterprise, JudgedFields,
        judgments: %{req_llm: AshEnterprise.SystemOne.TestSupport.FakeReqLLM},
        resolver: fn _family, _tenant, _inputs -> {:ok, evaluation} end
      )

      assert {nil, :stale, :stale} == fields!(ctx.task, ctx)
      assert %{success: 1} = Oban.drain_queue(queue: :system_one, with_safety: false)

      # One instrument call, for the retitled state and nothing else.
      assert_received {:judge_call, _spec, %{"title" => "SYNTHETIC book the larger venue"}, _}
      refute_received {:judge_call, _, _, _}

      # The band was recorded for this task and question, and the admit
      # revised the stale fact: the field reads the new value, fresh.
      assert [banding] =
               AshEnterprise.SystemOne.Banding
               |> Ash.read!(tenant: ctx.tenant, authorize?: false)

      assert banding.band == :admit
      assert {false, :admitted_false, nil} == fields!(ctx.task, ctx)

      # A revision, not a replacement: one id, the stale version preserved
      # in its own period.
      subject_id = ctx.task.id

      assert [revised] =
               Fact
               |> Ash.Query.filter(subject_id == ^subject_id)
               |> Ash.read!(authorize?: false)

      assert [stale] =
               Fact
               |> Ash.Query.filter(subject_id == ^subject_id)
               |> Ash.Query.as_of(revised.valid_at.lower |> DateTime.add(-1, :second))
               |> Ash.read!(authorize?: false)

      assert stale.id == revised.id
      assert {stale.value, revised.value} == {true, false}
    end
  end

  @doc false
  def capture_assessment(request, test_pid) do
    send(test_pid, {:assessed, request})
    {:ok, :captured}
  end

  defp restore_env(nil), do: Application.delete_env(:ash_enterprise, JudgedFields)
  defp restore_env(previous), do: Application.put_env(:ash_enterprise, JudgedFields, previous)
end

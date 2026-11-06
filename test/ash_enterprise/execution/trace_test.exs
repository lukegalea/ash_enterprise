defmodule AshEnterprise.Execution.TraceTest.Sources do
  @moduledoc false
  # Sources that misbehave, for the trace's reports: each answers one way and maps any
  # rows to one succeeded entry.

  defmacro __using__(answer) do
    quote do
      @behaviour AshAgent.Execution.Source

      @impl true
      def read(_scope, _opts), do: unquote(answer)

      @impl true
      def to_entries(rows) do
        for row <- rows,
            do:
              AshAgent.Execution.Source.entry(
                at: DateTime.utc_now(),
                kind: :effect,
                status: :succeeded,
                source_ref: "fake:#{row.id}"
              )
      end
    end
  end
end

defmodule AshEnterprise.Execution.TraceTest.Errors do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources, {:error, :database_unavailable}
end

defmodule AshEnterprise.Execution.TraceTest.Raises do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources, raise(ArgumentError, "source broke")
end

defmodule AshEnterprise.Execution.TraceTest.Hangs do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources,
      (receive do
         :never -> {:ok, [], nil}
       end)
end

defmodule AshEnterprise.Execution.TraceTest.AnswersNothing do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources, nil
end

defmodule AshEnterprise.Execution.TraceTest.AnswersOk do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources, :ok
end

defmodule AshEnterprise.Execution.TraceTest.AnswersNotRows do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources, {:ok, :rows, nil}
end

defmodule AshEnterprise.Execution.TraceTest.Reads do
  @moduledoc false
  use AshEnterprise.Execution.TraceTest.Sources, {:ok, [%{id: 1}], nil}
end

defmodule AshEnterprise.Execution.TraceTest do
  @moduledoc """
  The execution trace (`AshEnterprise.Execution.Entry`'s `trace`, over the sources in
  `AshEnterprise.ExecutionSources`) on the seeded clinic.

  The work traced is the clinic's own path, under one correlation id: the licence reader
  reads a credential's licence document (the evidence) and records its findings in the
  judgment ledger (the judgments); the review routing table decides who reviews it (the
  decision, with the rule that matched); the coordinator asks for the credential's
  activation, a committee member approves it (the approval), and the activation runs
  (its attempts) and is recorded by the registry (the effect).

  Then: what a person who may read none of it sees; that no sealed content reaches an
  entry; that a model call whose telemetry never arrived is not recorded; that each
  source reads at most its limit and pages by cursor; and that a source that fails,
  times out or answers with something other than rows is reported, never read as
  "nothing happened". SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshAgent.Execution.Status
  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing.{DemoData, RoutingTable}
  alias AshEnterprise.Decisions
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Entry, Invocation}
  alias AshEnterprise.Execution.TraceTest, as: Fake
  alias AshEnterprise.ExecutionSources
  alias AshEnterprise.ExecutionSources, as: S
  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"
  @number "DEMO-PT-0001"

  setup do
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)
    %{admin: admin, tenant: admin.tenant, clinic: clinic}
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp trace!(args, viewer, tenant), do: Execution.trace!(args, actor: viewer, tenant: tenant)

  # Steps and tool calls run as their jobs do, until nothing is left.
  defp drain!(rounds \\ 12)
  defp drain!(0), do: :ok

  defp drain!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: drain!(rounds - 1),
      else: :ok
  end

  # The clinic's path, under one correlation id: the reading, the routing decision, and
  # the activation, approved and run. Returns the correlation id, the run and the
  # activation.
  defp work!(%{clinic: clinic, tenant: tenant}) do
    correlation_id = Ash.UUID.generate()
    coordinator = actor(clinic.coordinator, tenant)
    credential = Enum.find(clinic.credentials, &(&1.number == @number))

    Correlation.with_correlation(correlation_id, fn ->
      {:ok, run} = Tour.start_reading(credential.id, coordinator)
      drain!()
      assert Execution.get_agent_run!(run.id, oban(tenant)).status == :completed

      RoutingTable.publish_next!(tenant)

      {:ok, %{matched_rule_ids: ["rule_route"]}} =
        Decisions.evaluate(RoutingTable.key(), %{"tier" => "standard"},
          tenant: tenant,
          correlation_id: correlation_id,
          record: :required
        )

      row =
        Execution.invoke!(
          @activate,
          %{"id" => credential.id},
          %{key: "trace:activate:#{credential.id}"},
          actor: coordinator,
          tenant: tenant
        )

      approve!(row, hd(clinic.committee), tenant)
      Execution.apply_invocation_decision!(row, oban(tenant))
      drain!()
      assert Execution.get_invocation!(row.id, oban(tenant)).status == :succeeded

      %{correlation_id: correlation_id, run: run, activation: row}
    end)
  end

  defp approve!(row, member, tenant) do
    row_id = row.id
    approval = Approval.key()

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^row_id and node_id == ^approval)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    {:ok, _} =
      HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
        actor: actor(member, tenant),
        tenant: tenant
      )
      |> Ash.run_action()
  end

  defp index(entries, fun), do: Enum.find_index(entries, fun)

  describe "trace(correlation_id)" do
    test "follows evidence, judgment, decision, approval, attempts and effect in order", ctx do
      %{correlation_id: id, run: run, activation: activation} = work!(ctx)

      %{entries: entries, sources: sources} =
        trace!(%{correlation_id: id}, ctx.admin.actor, ctx.tenant)

      assert Enum.all?(entries, &match?(%Entry{}, &1))
      assert Enum.all?(sources, &(&1.status == :complete)), inspect(sources)
      assert Enum.map(sources, & &1.source) == ExecutionSources.names()

      # Oldest first.
      assert entries == Enum.sort_by(entries, & &1.at, DateTime)

      activation_ref = "invocation:#{activation.id}"

      evidence =
        index(entries, &(&1.source == :step and &1.kind == :observation))

      judgment = index(entries, &(&1.source == :judgment))

      decision =
        index(entries, &(&1.source == :evaluation and &1.summary =~ "rule_route"))

      approval =
        index(entries, &(&1.source == :human_task and &1.parent_ref == activation_ref))

      attempt = index(entries, &(&1.kind == :attempt and &1.parent_ref == activation_ref))
      effect = index(entries, &(&1.kind == :effect and &1.parent_ref == activation_ref))

      assert Enum.all?([evidence, judgment, decision, approval, attempt, effect], &is_integer/1),
             inspect(Enum.map(entries, &{&1.source, &1.kind, &1.summary}), pretty: true)

      assert evidence < judgment
      assert judgment < decision
      assert decision < approval
      assert approval < attempt
      assert attempt < effect

      # What each says.
      by_ref = Map.new(entries, &{&1.source_ref, &1})

      assert %{kind: :logical_operation, status: :succeeded} = by_ref["run:#{run.id}"]
      assert %{kind: :logical_operation, status: :succeeded} = by_ref[activation_ref]

      assert %{kind: :decision, status: :succeeded, definition_ref: decision_ref} =
               Enum.at(entries, decision)

      assert decision_ref =~ ~r/^credentialing\.review_route@\d+$/

      assert %{kind: :approval, status: :succeeded, actor_label: "person:" <> member_id} =
               Enum.at(entries, approval)

      assert member_id == hd(ctx.clinic.committee).id
      assert %{status: :succeeded, summary: "attempt 1: succeed"} = Enum.at(entries, attempt)

      # A synchronous target records no external reference on the invocation (only a
      # dispatch or a reconciliation does), so the effect names what was done.
      assert %{status: :succeeded, definition_ref: @activate, summary: @activate} =
               Enum.at(entries, effect)

      # The judgments sit under the tool call that recorded them, and the steps and model
      # calls under the run.
      run_ref = "run:#{run.id}"
      assert %{parent_ref: "invocation:" <> _} = Enum.at(entries, judgment)
      assert Enum.any?(entries, &(&1.source == :model_call and &1.parent_ref == run_ref))
      assert Enum.all?(Enum.filter(entries, &(&1.source == :step)), &(&1.parent_ref == run_ref))

      for entry <- entries do
        assert entry.status in Status.statuses()
        assert entry.kind in AshAgent.Execution.Source.kinds()
      end
    end

    test "rows the viewer may not read are not in it, and sealed content never is", ctx do
      %{correlation_id: id} = work!(ctx)

      porter = member!(ctx.admin, "Porter #{System.unique_integer([:positive])}", [])

      assert %{entries: [], sources: sources} =
               trace!(%{correlation_id: id}, porter.actor, ctx.tenant)

      assert Enum.all?(sources, &(&1.status == :complete))

      # Everything the administrator may read, and none of what is sealed in it: the
      # document's text, the reader's input, the findings' cited lines.
      result = trace!(%{correlation_id: id}, ctx.admin.actor, ctx.tenant)
      assert result.entries != []
      rendered = inspect(result, limit: :infinity, printable_limit: :infinity)

      refute rendered =~ @number
      refute rendered =~ "Licence number"
    end

    test "a model call whose telemetry never arrived is not recorded, and costs nothing known",
         ctx do
      id = Ash.UUID.generate()

      call = fn tokens ->
        ModelCall.record!(
          %{
            caller: "trace.test",
            profile: "recorded",
            model: "synthetic",
            residency: :in_zone,
            operation: :generate_text,
            outcome: :ok,
            correlation_id: id,
            input_tokens: tokens,
            output_tokens: tokens,
            duration_ms: tokens && 40
          },
          actor: SystemActor.system()
        )
      end

      measured = call.(12)
      unmeasured = call.(nil)

      %{entries: entries} = trace!(%{correlation_id: id}, ctx.admin.actor, ctx.tenant)
      by_ref = Map.new(entries, &{&1.source_ref, &1})

      assert %{recorded?: true, cost: %{tokens: 24, duration_ms: 40}} =
               by_ref["model_call:#{measured.id}"]

      assert %{recorded?: false, cost: nil, status: :succeeded} =
               by_ref["model_call:#{unmeasured.id}"]
    end
  end

  describe "trace(root_ref)" do
    test "follows the records that point at it", ctx do
      %{run: run} = work!(ctx)

      %{entries: entries} = trace!(%{root_ref: "run:#{run.id}"}, ctx.admin.actor, ctx.tenant)

      sources = entries |> Enum.map(& &1.source) |> Enum.uniq()
      assert :run in sources and :step in sources and :invocation in sources
      assert :judgment in sources
    end

    test "takes a correlation id or a reference, one of them, well formed", ctx do
      viewer = ctx.admin.actor

      for args <- [
            %{},
            %{correlation_id: "a", root_ref: "run:#{Ash.UUID.generate()}"},
            %{root_ref: "run:not-a-uuid"},
            %{root_ref: "nothing"}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Execution.trace(args, actor: viewer, tenant: ctx.tenant)
      end
    end
  end

  describe "limits and cursors" do
    test "a source reads at most its limit, and its cursor reads the rest", ctx do
      id = Ash.UUID.generate()

      calls =
        for n <- 1..5 do
          ModelCall.record!(
            %{
              caller: "trace.test.#{n}",
              profile: "recorded",
              model: "synthetic",
              residency: :in_zone,
              operation: :generate_text,
              outcome: :ok,
              correlation_id: id
            },
            actor: SystemActor.system()
          )
        end

      sources = [{:model_call, S.ModelCall, limit: 2}]
      scope = %{correlation_id: id, refs: MapSet.new()}
      opts = [actor: ctx.admin.actor, tenant: ctx.tenant]

      pages =
        Stream.unfold(%{}, fn
          :done ->
            nil

          cursors ->
            {entries, [report]} =
              ExecutionSources.collect(sources, scope, [cursors: cursors] ++ opts)

            assert length(entries) <= 2
            next = if report.status == :more, do: %{model_call: report.cursor}, else: :done
            {{entries, report}, next}
        end)
        |> Enum.to_list()

      assert Enum.map(pages, fn {_entries, report} -> report.status end) ==
               [:more, :more, :complete]

      # Every call once, none twice.
      read = pages |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(& &1.source_ref)
      assert Enum.sort(read) == Enum.sort(Enum.map(calls, &"model_call:#{&1.id}"))

      # A cursor that does not parse is the source's failure, not an empty page.
      {[entry], [report]} =
        ExecutionSources.collect(sources, scope, [cursors: %{"model_call" => "garbage"}] ++ opts)

      assert report.status == :failed
      assert {entry.status, entry.recorded?} == {:uncertain, false}
    end

    test "every registered source declares a limit" do
      for {_name, module, opts} <- ExecutionSources.all() do
        assert is_integer(opts[:limit]) and opts[:limit] > 0
        assert function_exported?(Code.ensure_loaded!(module), :read, 2)
        assert function_exported?(module, :to_entries, 1)
      end
    end
  end

  describe "a source that cannot be read" do
    @scope %{correlation_id: "c", refs: MapSet.new()}

    test "is reported with why, and leaves an uncertain, unrecorded entry on the timeline" do
      sources = [
        {:errors, Fake.Errors, limit: 5},
        {:raises, Fake.Raises, limit: 5},
        {:hangs, Fake.Hangs, limit: 5, timeout: 50},
        {:answers_nothing, Fake.AnswersNothing, limit: 5},
        {:answers_ok, Fake.AnswersOk, limit: 5},
        {:answers_not_rows, Fake.AnswersNotRows, limit: 5},
        {:reads, Fake.Reads, limit: 5}
      ]

      {entries, reports} = ExecutionSources.collect(sources, @scope, [])
      by_source = Map.new(reports, &{&1.source, &1})

      assert by_source.errors.status == :failed
      assert by_source.errors.error =~ "database_unavailable"
      assert by_source.raises.status == :failed
      assert by_source.raises.error =~ "source broke"
      assert by_source.hangs.status == :timed_out
      assert by_source.answers_nothing.status == :unanswered
      assert by_source.answers_ok.status == :unanswered
      assert by_source.answers_not_rows.status == :unanswered

      # The source after them still reads.
      assert by_source.reads.status == :complete

      assert [%{status: :succeeded, source: :reads}] =
               Enum.filter(entries, &(&1.source == :reads))

      unread = Enum.reject(entries, &(&1.source == :reads))
      assert length(unread) == 6

      for entry <- unread do
        assert entry.status == :uncertain
        assert entry.recorded? == false
        assert entry.source_ref == "source:#{entry.source}"
        assert entry.summary =~ "not read"
      end
    end
  end

  describe "the shared status" do
    test "an invocation waiting for more information waits on its requester" do
      row = %Invocation{
        id: Ash.UUID.generate(),
        status: :request_info,
        target: @activate,
        target_digest: "abc",
        effects: %{},
        created_on: DateTime.utc_now(),
        modified_on: DateTime.utc_now(),
        recorded?: true
      }

      assert [%{kind: :logical_operation, status: :waiting, blocked_on: :requester}] =
               S.Invocation.to_entries([row])
    end

    test "an outcome a source cannot place is uncertain, never a success" do
      assert S.HumanTask.status(%{status: :completed, outcome: nil}) == {:uncertain, nil}
      assert S.HumanTask.status(%{status: :paused}) == {:uncertain, nil}
      assert S.HumanTask.status(%{status: :open}) == {:waiting, :human}
      assert S.HumanTask.status(%{status: :completed, outcome: "rejected"}) == {:cancelled, nil}
      assert S.ProcessEvent.status(:a_kind_added_later) == :uncertain
      assert S.ProcessEvent.status(:action_failed) == :failed
      assert S.CaseResult.status(:unmeasured) == :uncertain
      assert S.CaseResult.status(:errored) == :failed
      assert S.CaseResult.status(nil) == :uncertain
    end
  end

  test "a tenant's Administrator role reaches the trace through the privilege catalogue", ctx do
    name = inspect(Entry)

    assert [%{access_right: :read}] =
             Security.Privilege
             |> Ash.Query.filter(resource_name == ^name and access_right == :read)
             |> Ash.read!(authorize?: false)

    assert %{entries: []} =
             trace!(%{correlation_id: Ash.UUID.generate()}, ctx.admin.actor, ctx.tenant)
  end
end

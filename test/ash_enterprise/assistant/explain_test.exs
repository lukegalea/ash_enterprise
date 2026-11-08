defmodule AshEnterprise.Assistant.ExplainTest do
  @moduledoc """
  The assistant's `trace`, `explain` and `stalled_reviews` tools (AGT-61): "why did this
  happen?" answered from the execution record as the asker may read it, and "show
  stalled reviews" answered with a view that is also a page of its own.

  On the seeded clinic: the coordinator asks to activate a credential, a committee
  member approves, the registry accepts and its answer is lost (the showcase's
  lose-the-answer control, F2), so the activation's outcome is unknown. The coordinator
  then asks the assistant why. The model's turns are scripted (no model, no network):
  what is tested is what the tools hand it and what the page lets its answer cite.

  The negative tests drive `AshEnterprise.Assistant.Lookups.Work.rows/4` with a trace's
  own gap entries: a source that fails, a source cut short, an entry never recorded, a
  status no one knows and a record the asker may not read are each said, never dropped
  into "nothing happened".
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  alias AshEnterprise.Assistant.{Answer, Composer, Turn}
  alias AshEnterprise.Assistant.Lookups.Work
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Execution
  alias AshEnterprise.ExecutionSources
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.Execution.Runs

  @reasoning "SYNTHETIC-REASONING the hidden chain of thought"

  defp person(ctx, user), do: %{actor: F.actor(user, ctx.tenant), user: user, tenant: ctx.tenant}

  defp oban(ctx), do: [actor: SystemActor.oban(), tenant: ctx.tenant]

  defp drain, do: Oban.drain_queue(queue: :execution, with_recursion: true)

  # Every ref the run's tools returned, read off its journal.
  defp returned_refs(answer), do: MapSet.new(answer.refs)

  # The tool results in the run's journal, in order, as the text the model read.
  defp tool_results(run) do
    Execution.list_agent_steps!(
      query: [filter: [run_id: run.id], sort: [seq: :asc]],
      authorize?: false,
      tenant: run.organization_id
    )
    |> Ash.load!(:parts, authorize?: false)
    |> Enum.flat_map(&(&1.parts || []))
    |> Enum.filter(&(&1["type"] == "tool_result"))
    |> Enum.map(&content/1)
  end

  defp content(%{"content" => text}) when is_binary(text), do: text
  defp content(%{"content" => other}), do: Jason.encode!(other)

  describe "explaining the clinic's uncertain activation (F2)" do
    @describetag evidence: true
    @describetag timeout: 240_000

    setup do
      on_exit(&Faults.disarm_all/0)
      F.in_zone!()
      ctx = F.tenant!()
      clinic = DemoData.populate(ctx.tenant)
      rosa = person(ctx, clinic.coordinator)
      F.published!(ctx, [rosa])
      Map.merge(ctx, %{clinic: clinic, rosa: rosa})
    end

    # The fault control, the coordinator's ask, a committee member's approval and the
    # jobs after it: the registry took the activation and its answer was lost.
    defp uncertain!(ctx) do
      credential = Enum.find(ctx.clinic.credentials, &(&1.number == "DEMO-PT-0001"))
      assert :ok = Tour.lose_registry_answer()

      assert {:ok, _} =
               Credentialing.request_activation(credential.id,
                 actor: ctx.rosa.actor,
                 tenant: ctx.tenant
               )

      request =
        ctx.rosa.actor |> Tour.activations() |> Enum.find(&(&1.credential_id == credential.id))

      member = person(ctx, hd(ctx.clinic.committee))

      HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: request.task_id},
        actor: member.actor,
        tenant: ctx.tenant
      )
      |> Ash.run_action!()

      Execution.apply_invocation_decision!(request.invocation, oban(ctx))
      drain()

      row = Execution.get_invocation!(request.invocation.id, oban(ctx))
      assert row.status == :outcome_unknown
      row
    end

    test "the answer cites only refs the asker can read, says uncertain, and carries no reasoning",
         ctx do
      row = uncertain!(ctx)
      ref = "invocation:#{row.id}"
      # An id the asker never got from a tool: a guess, or someone else's record.
      forged = "invocation:#{Ash.UUID.generate()}"

      ScriptedModel.script!([
        {:tools, [{"explain", %{"input" => %{"ref" => ref}}}]},
        {:tools, [{"trace", %{"input" => %{"ref" => ref}}}]},
        {:think, @reasoning,
         {:text,
          "SYNTHETIC: The registry took the activation, but its answer was lost, so the " <>
            "outcome is uncertain [[#{ref}]]. Another request [[#{forged}]] was not involved."}}
      ])

      thread = F.thread!(ctx.rosa)

      assert {:ok, %Turn{status: :complete} = answer} =
               F.ask!(ctx.rosa, thread, "SYNTHETIC: why is #{ref} not finished?")

      # It explained the record and traced it: both are reads in the loop, nothing written.
      assert [run] =
               Execution.list_agent_runs!(
                 authorize?: false,
                 tenant: ctx.tenant,
                 query: [filter: [agent_key: "assistant"]]
               )

      assert Runs.invocations(run) == []

      assert [%{"name" => "explain", "ok" => true}, %{"name" => "trace", "ok" => true}] =
               answer.tool_calls["calls"]

      # The record the asker asked about is the subject, uncertain, and its meaning says so.
      [explained, traced] = tool_results(run)
      assert explained =~ ~s("role":"subject")
      assert explained =~ ~s("ref":"#{ref}")
      assert explained =~ ~s("status":"uncertain")
      assert explained =~ "may or may not have happened"
      assert traced =~ ~s("ref":"#{ref}")

      # Every ref the tools returned is one the asker can read: each opens a trace as them
      # in which that record is an entry.
      refs = returned_refs(answer)
      assert ref in refs
      refute forged in refs

      for returned <- refs do
        assert Work.citable?(returned) or Surfaces.fetch(hd(String.split(returned, ":")))

        if Work.citable?(returned) do
          %{entries: entries} =
            Execution.trace!(%{root_ref: returned}, actor: ctx.rosa.actor, tenant: ctx.tenant)

          assert Enum.any?(entries, &(&1.source_ref == returned))
        end
      end

      # On the page: the readable ref is a numbered link to the explorer rooted there; the
      # forged one is dropped, not linked.
      %{sources: sources} = Answer.parse(answer.content, answer.refs)
      assert [%{ref: ^ref, path: path}] = sources
      assert path == Work.explorer_path(ref)
      assert path =~ "/app/explorer?"

      # No provider reasoning in the answer, its recorded text or what the tools returned.
      refute answer.content =~ "SYNTHETIC-REASONING"
      refute Jason.encode!(answer.tool_calls) =~ "SYNTHETIC-REASONING"
      refute Enum.any?(tool_results(run), &(&1 =~ "SYNTHETIC-REASONING"))
    end

    test "a person who may not read the activation is told it is missing, with nothing to cite",
         ctx do
      row = uncertain!(ctx)
      ref = "invocation:#{row.id}"
      outsider = F.colleague!(ctx)

      rows = F.tool!(outsider, :explain, %{ref: ref})

      assert [%{"role" => :missing, "status" => :uncertain, "missing" => missing} | _] = rows
      assert missing =~ "No record #{ref} that you may read"
      assert missing =~ "not the same as nothing having happened"
      refute Enum.any?(rows, &Map.has_key?(&1, "ref"))
      refute Enum.any?(rows, &(&1["status"] == :succeeded))

      # The coordinator, who asked for it, reads it.
      assert [%{"role" => :subject, "ref" => ^ref, "status" => :uncertain} | _] =
               F.tool!(ctx.rosa, :explain, %{ref: ref})
    end

    test "a ref that differs only in letter case explains the same record", ctx do
      row = uncertain!(ctx)
      ref = "invocation:#{row.id}"

      assert [%{"role" => :subject, "ref" => ^ref, "status" => :uncertain} | _] =
               F.tool!(ctx.rosa, :explain, %{ref: "invocation:" <> String.upcase(row.id)})
    end

    test "an activation whose content was erased is said to be not recorded", ctx do
      row = uncertain!(ctx)
      ref = "invocation:#{row.id}"

      # The request's arguments are shredded with the scope they were sealed under, as
      # an erasure does; erasing is a platform operator's act.
      Seeder.grant_platform_operator(ctx.user)
      operator = F.actor(ctx.user, ctx.tenant)
      scope = Ash.get!(Scope, row.erasure_scope_id, authorize?: false)

      assert {:ok, %{status: :shredded}} =
               Erasure.shred_scope(scope, scope.ref, "SYNTHETIC erasure", actor: operator)

      assert [%{"role" => :subject, "ref" => ^ref} = subject | _] =
               F.tool!(ctx.rosa, :explain, %{ref: ref})

      assert subject["missing"] =~ "Not recorded"
      assert subject["missing"] =~ "content is not known"
      assert subject["status"] == :uncertain
    end

    test "stalled reviews: the tool's view is the declared surface's read, as the reader", ctx do
      # DEMO-SLT-0004's approval has waited three days; a fresh one has not.
      waiting = Enum.find(ctx.clinic.credentials, &(&1.number == "DEMO-SLT-0004"))

      %{task_id: stalled_id} =
        ctx.rosa.actor |> Tour.activations() |> Enum.find(&(&1.credential_id == waiting.id))

      three_days_ago = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)

      {1, _} =
        AshEnterprise.Repo.update_all(
          Ecto.Query.from(t in "bpmn_human_tasks", where: t.id == type(^stalled_id, Ecto.UUID)),
          set: [inserted_at: three_days_ago]
        )

      fresh = Enum.find(ctx.clinic.credentials, &(&1.number == "DEMO-RN-0002"))

      {:ok, _} =
        Credentialing.request_activation(fresh.id, actor: ctx.rosa.actor, tenant: ctx.tenant)

      member = person(ctx, hd(ctx.clinic.committee))

      assert [row] = F.tool!(member, :stalled_reviews, %{})
      assert row["count"] == 1
      assert [%{ref: review_ref}] = row["reviews"]
      assert review_ref =~ stalled_id
      assert row["page"] == "/app/reviews/stalled"

      # The view it put on screen composes, and reads the stalled-reviews surface's action.
      assert {:ok, composed} = Composer.compose(row["surface"])
      assert [%{"read_action" => "stalled"}] = composed.spec["components"]

      # The declared surface reads the same action, and the registry routes and names it.
      surface = Surfaces.fetch!(:stalled_reviews)
      assert surface.path == row["page"]
      assert surface.ui == AshEnterpriseWeb.A2ui.StalledReviewsUI
      assert surface in Surfaces.generated()

      assert [%{read_action: :stalled}] =
               AshA2ui.Info.components(AshEnterpriseWeb.A2ui.StalledReviewsUI)

      assert [%{id: ^stalled_id}] =
               HumanTask
               |> Ash.Query.for_read(:stalled, %{}, actor: member.actor, tenant: ctx.tenant)
               |> Ash.read!()

      # Someone with no grant and no candidacy sees none, and is told so: not an error.
      outsider = F.colleague!(ctx)
      assert [%{"count" => 0, "note" => note}] = F.tool!(outsider, :stalled_reviews, %{})
      assert note =~ "None of the tasks"
    end
  end

  describe "what the tools say when the record is incomplete" do
    # Rows from real gap entries: the registry's own collector, over sources that fail,
    # are cut short, or answer with an unrecorded entry.
    defmodule Fails do
      @moduledoc false
      @behaviour AshAgent.Execution.Source
      def read(_scope, _opts), do: {:error, "SYNTHETIC connection refused"}
      def to_entries(_rows), do: []
    end

    defmodule More do
      @moduledoc false
      @behaviour AshAgent.Execution.Source
      def read(_scope, _opts), do: {:ok, [:row], "next-page"}

      def to_entries(_rows) do
        [
          AshAgent.Execution.Source.entry(
            at: DateTime.utc_now(),
            kind: :logical_operation,
            status: :running,
            source_ref: "invocation:#{Ash.UUID.generate()}",
            summary: "SYNTHETIC request"
          )
        ]
      end
    end

    defmodule Unrecorded do
      @moduledoc false
      @behaviour AshAgent.Execution.Source
      def read(_scope, _opts), do: {:ok, [:row], nil}

      def to_entries(_rows) do
        [
          AshAgent.Execution.Source.entry(
            at: DateTime.utc_now(),
            kind: :proposal,
            status: :succeeded,
            source_ref: "step:#{Ash.UUID.generate()}",
            parent_ref: "run:#{Ash.UUID.generate()}",
            recorded?: false,
            summary: "step 1: model turn"
          )
        ]
      end
    end

    defp collect(sources) do
      ExecutionSources.collect(sources, %{correlation_id: "synthetic", refs: MapSet.new()},
        actor: nil,
        tenant: nil,
        cursors: %{}
      )
    end

    defp rows(op, args, sources) do
      {entries, reports} = collect(sources)
      Work.rows(op, args, Enum.map(entries, &struct!(Execution.Entry, &1)), reports)
    end

    test "a source that fails is said as not read, never as nothing happened" do
      assert [row] = rows(:trace, %{correlation_id: "synthetic"}, [{:fails, Fails, limit: 5}])

      assert row.role == :missing
      assert row.status == :uncertain
      assert row.missing =~ "Not read: fails not read (failed)"
      assert row.missing =~ "SYNTHETIC connection refused"
      assert row.missing =~ "may exist that are not shown"
      assert is_nil(row.ref) and is_nil(row.entry)
    end

    test "a source cut short at its limit says the trace is not everything" do
      rows = rows(:trace, %{correlation_id: "synthetic"}, [{:invocation, More, limit: 1}])

      assert [%{role: :entry, status: :running}, cut] = rows
      assert cut.role == :missing and cut.status == :uncertain
      assert cut.missing =~ "Cut short"
      assert cut.missing =~ "not everything"
    end

    test "an entry whose content was not recorded is said, and its status kept" do
      assert [row] = rows(:trace, %{correlation_id: "synthetic"}, [{:step, Unrecorded, limit: 5}])

      assert row.role == :entry
      assert row.status == :succeeded
      assert row.missing =~ "Not recorded"
      # A journal step is part of a run: named, not citable.
      assert is_nil(row.ref)
      assert row.entry =~ "step:"
    end

    test "a status no one knows reads as uncertain, never as done" do
      entry = %Execution.Entry{
        at: DateTime.utc_now(),
        kind: :effect,
        status: :uncertain,
        source_ref: "effect:#{Ash.UUID.generate()}",
        recorded?: true
      }

      assert [row] = Work.rows(:trace, %{correlation_id: "x"}, [%{entry | status: :mystery}], [])
      assert row.meaning =~ "uncertain: it may or may not have happened"
    end

    test "explaining a record the trace did not find says so, and keeps the gaps" do
      ref = "invocation:#{Ash.UUID.generate()}"
      rows = rows(:explain, %{root_ref: ref}, [{:fails, Fails, limit: 5}, {:x, More, limit: 1}])

      assert [not_found | rest] = rows
      assert not_found.role == :missing
      assert not_found.missing =~ "No record #{ref} that you may read"
      # The gaps stay: the record may be in the source that could not be read.
      assert Enum.any?(rest, &(&1.missing =~ "Not read"))
      assert Enum.any?(rest, &(&1.missing =~ "Cut short"))
      # What was read is not about this record, so none of it is offered as its story.
      assert Enum.all?(rest, &(&1.role == :missing))
    end

    test "a trace longer than one answer carries says how many are not shown" do
      entries =
        for n <- 1..61 do
          %Execution.Entry{
            at: DateTime.add(DateTime.utc_now(), n, :second),
            kind: :observation,
            status: :succeeded,
            source_ref: "process_event:#{Ash.UUID.generate()}",
            recorded?: true
          }
        end

      rows = Work.rows(:trace, %{correlation_id: "x"}, entries, [])
      assert length(rows) == 61
      assert List.last(rows).missing =~ "1 more entries were read but are not shown"
    end

    test "the tools answer only an in-zone run, and refuse a caller with none" do
      F.in_zone!()
      ctx = F.tenant!()

      for {tool, input} <- [
            {:trace, %{correlation_id: "synthetic"}},
            {:explain, %{ref: "invocation:#{Ash.UUID.generate()}"}},
            {:stalled_reviews, %{}}
          ] do
        assert F.refusal(ctx, tool, input, run?: false) =~ "Refused"
      end

      assert F.refusal(ctx, :trace, %{}) =~ "Give ref or correlation_id"

      assert F.refusal(ctx, :trace, %{
               ref: "invocation:#{Ash.UUID.generate()}",
               correlation_id: "x"
             }) =~ "not both"
    end
  end
end

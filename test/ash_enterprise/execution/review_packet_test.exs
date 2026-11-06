defmodule AshEnterprise.Execution.ReviewPacketTest do
  @moduledoc """
  The review packet over an invocation's approval task, and a reviewer's request for more
  information (R2 HW-02..06, N4; AGT-51).

  A nurse asks to retitle one of their clinic notes through a target a clinic lead
  approves (`AshEnterprise.Test.Execution.ClinicNote.retitle_reviewed`). The lead reads
  the packet beside the task: what would run, with what, the digest a decision binds,
  whether it still binds, the evidence and decisions behind it, when it is due and
  whether it escalated. A lead who cannot decide yet asks the nurse a question
  (`HumanTask.request_info`): the request waits in `request_info` with a task for the
  nurse, and only an answer, then a later approval, makes it ready.

  Durability tier: the steps commit for real; the `:execution` queue is paused so each
  test drives the triggers by hand.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Bpmn.{HumanTask, ProcessEvent}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, InfoRequest, ReviewPacket}
  alias AshEnterprise.Repo
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.ClinicNote

  @retitle "AshEnterprise.Test.Execution.ClinicNote.retitle_reviewed"
  @lead_role "Clinic lead"

  @packet [
    :review_target,
    :review_arguments,
    :review_digest,
    :review_currency,
    :review_evidence,
    :review_decision,
    :due_label,
    :escalation_label,
    :info_exchange
  ]

  setup do
    subscribe_jobs()
    pause_execution!()
    %{admin: admin, nurse: nurse, tenant: tenant} = clinic!()

    lead = DailyFixtures.member!(admin, @lead_role, [])
    bystander = DailyFixtures.member!(admin, "Porter #{unique()}", [])

    note =
      Ash.create!(ClinicNote, %{title: "Ask the lab about the panel #{unique()}"},
        action: :record,
        actor: nurse.actor,
        tenant: tenant
      )

    %{admin: admin, nurse: nurse, lead: lead, bystander: bystander, note: note, tenant: tenant}
  end

  defp unique, do: System.unique_integer([:positive])
  defp fresh(person), do: DailyFixtures.actor(person.user)

  defp request!(ctx, title \\ nil) do
    {:ok, row} =
      invoke(
        ctx.nurse,
        @retitle,
        %{"id" => ctx.note.id, "title" => title || "Lab panel to the chart #{unique()}"},
        "retitle:#{unique()}"
      )

    row
  end

  defp latest_task(row, key, tenant) do
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp approval_task(row, tenant), do: latest_task(row, Approval.key(), tenant)
  defp info_task(row, tenant), do: latest_task(row, InfoRequest.key(), tenant)

  defp door(action, task, person, args, ctx) do
    HumanTask
    |> Ash.ActionInput.for_action(action, Map.put(args, :record_id, task.id),
      actor: fresh(person),
      tenant: ctx.tenant
    )
    |> Ash.run_action()
  end

  defp apply_decision(row, ctx), do: Execution.apply_invocation_decision(row, oban(ctx.tenant))
  defp provide_info(row, ctx), do: Execution.provide_invocation_info(row, oban(ctx.tenant))

  defp packet!(task, person, ctx) do
    Ash.load!(task, @packet, actor: fresh(person), tenant: ctx.tenant)
  end

  # A task's columns written past the actions, as a clock or a broken writer would.
  defp task_set!(task, set) do
    {1, _} =
      Repo.update_all(
        from(t in "bpmn_human_tasks", where: t.id == type(^task.id, Ecto.UUID)),
        set: set
      )

    :ok
  end

  defp written_elsewhere!(ctx) do
    ctx.note.id
    |> then(&Ash.get!(ClinicNote, &1, authorize?: false, tenant: ctx.tenant))
    |> Ash.Changeset.for_update(:retitle, %{title: "Changed meanwhile #{unique()}"},
      authorize?: false,
      tenant: ctx.tenant
    )
    |> Ash.update!()
  end

  describe "the packet" do
    test "shows what would run, with what, the digest bound, and that it still binds", ctx do
      title = "Lab panel to the chart #{unique()}"
      row = request!(ctx, title)
      packet = packet!(approval_task(row, ctx.tenant), ctx.lead, ctx)

      assert packet.review_target =~ @retitle
      assert packet.review_target =~ "approval four_eyes"
      assert packet.review_arguments =~ "title (string, optional): #{title}"
      assert packet.review_arguments =~ "id (string): #{ctx.note.id}"
      assert packet.review_digest == row.approval_digest
      assert packet.review_currency =~ "Current"
      assert packet.review_evidence =~ "ClinicNote:#{ctx.note.id}@"
      assert packet.review_decision == "No decision was evaluated."
      assert packet.due_label =~ "approval window closes"
      assert packet.escalation_label == "Not escalated."
      assert packet.info_exchange == nil
    end

    test "shows stale, and why, once the digest no longer matches the request", ctx do
      row = request!(ctx)
      written_elsewhere!(ctx)

      packet = packet!(approval_task(row, ctx.tenant), ctx.lead, ctx)
      assert packet.review_currency == "Stale: subject_changed"
      refute packet.review_currency =~ "Current"
    end

    test "a tampered digest reads stale (approval_changed), never current", ctx do
      row = request!(ctx)
      tampered = %{committed(row.id, ctx.tenant) | approval_digest: String.duplicate("0", 64)}

      assert ReviewPacket.currency(tampered) == {:stale, "approval_changed"}
    end

    test "nothing it cannot establish reads as current", ctx do
      row = committed(request!(ctx).id, ctx.tenant)

      assert ReviewPacket.currency(%{row | approval_digest: nil}) == {:unknown, :unbound}

      assert ReviewPacket.currency(%{row | target: "Nowhere.at_all"}) ==
               {:stale, "target_changed"}

      assert ReviewPacket.currency(nil) == {:unknown, :unreadable}
      assert ReviewPacket.currency(%{status: nil}) == {:unknown, :unreadable}
      assert ReviewPacket.currency(%{row | status: :stale, error_code: nil}) == {:stale, :unknown}
      assert ReviewPacket.currency(%{row | status: :ready}) == {:decided, :ready}
    end

    test "a reader who may see the task but not the request learns nothing about it", ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)

      # Built as a reader the invocation's policies refuse.
      packet = ReviewPacket.build(task, actor: fresh(ctx.bystander), tenant: ctx.tenant)

      assert packet.invocation == nil
      assert packet.currency == {:unknown, :unreadable}
      assert packet.arguments == :unreadable
      assert packet.target == :unreadable
      assert packet.digest == :unreadable
    end

    test "is nil on a task that is not an invocation's approval", ctx do
      assert ReviewPacket.build(%{subject_type: "x", node_id: "y", instance_id: nil}, []) ==
               nil

      task = approval_task(request!(ctx), ctx.tenant)
      assert ReviewPacket.build(%{task | node_id: "invocation.input"}, []) == nil
    end

    test "shows when the task is due and that it escalated", ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)
      due_at = DateTime.add(DateTime.utc_now(), 2, :day)

      task_set!(task, due_at: due_at)

      Ash.create!(
        ProcessEvent,
        %{
          task_id: task.id,
          kind: :timer_fired,
          data: %{"timer_kind" => "escalate", "handler" => "resolver"}
        },
        action: :create,
        authorize?: false,
        tenant: ctx.tenant
      )

      packet = packet!(approval_task(row, ctx.tenant), ctx.lead, ctx)
      assert packet.due_label =~ "Due #{AshEnterprise.Platform.LocalTime.stamp(due_at)}"
      assert packet.escalation_label =~ "Escalated"
    end
  end

  describe "a request for more information" do
    test "parks the request with a task for the requester; only an answer and then an approval make it ready",
         ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)

      # The requester may not ask on their own request; the lead may.
      assert {:error, _} = door(:request_info, task, ctx.nurse, %{question: "Q?"}, ctx)

      assert {:ok, _} =
               door(:request_info, task, ctx.lead, %{question: "Which lab sent it?"}, ctx)

      parked = Execution.apply_invocation_decision!(row, oban(ctx.tenant))
      assert {parked.status, parked.approved_by_id} == {:request_info, nil}

      # The requester is asked, in the same transaction.
      asked = info_task(row, ctx.tenant)
      assert asked.status == :open
      assert asked.due_at

      # Nothing decides a parked request, and nothing runs it.
      assert {:error, _} = apply_decision(parked, ctx)
      assert {:ok, :skipped} = Executor.execute(parked.__struct__, parked.id, oban(ctx.tenant))
      assert committed(row.id, ctx.tenant).status == :request_info

      # Until the requester answers, it does not go back to the approver.
      assert {:error, _} = provide_info(parked, ctx)
      assert committed(row.id, ctx.tenant).status == :request_info

      # Only the requester answers, and only through answer.
      assert {:error, _} = door(:answer, asked, ctx.lead, %{answer: "SYNTHETIC: me"}, ctx)
      assert {:error, _} = door(:approve, asked, ctx.nurse, %{}, ctx)

      assert {:ok, _} =
               door(:answer, asked, ctx.nurse, %{answer: "SYNTHETIC: the city lab"}, ctx)

      back = provide_info(parked, ctx) |> elem(1)
      assert back.status == :awaiting_approval

      # A new approval task, and the packet carries the exchange.
      again = approval_task(row, ctx.tenant)
      assert again.id != task.id
      assert again.status == :open

      packet = packet!(again, ctx.lead, ctx)
      assert packet.info_exchange =~ "Which lab sent it?"
      assert packet.info_exchange =~ "SYNTHETIC: the city lab"
      assert packet.review_currency =~ "Current"

      assert {:ok, _} = door(:approve, again, ctx.lead, %{}, ctx)
      ready = Execution.apply_invocation_decision!(back, oban(ctx.tenant))
      assert {ready.status, ready.approved_by_id} == {:ready, ctx.lead.user.id}
    end

    test "a request still waiting on its answer shows the question as unanswered", ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)
      assert {:ok, _} = door(:request_info, task, ctx.lead, %{question: "Which ward?"}, ctx)
      Execution.apply_invocation_decision!(row, oban(ctx.tenant))

      # The lead's task is decided, so they no longer read the request; the requester,
      # asked, reads the exchange as it stands.
      packet =
        approval_task(row, ctx.tenant)
        |> ReviewPacket.build([actor: fresh(ctx.nurse), tenant: ctx.tenant], [:questions])

      exchange = AshEnterprise.Bpmn.Calculations.ReviewPacket.render(:questions, packet.questions)
      assert exchange =~ "Which ward?"
      assert exchange =~ "Waiting for the requester's answer, due"

      assert ReviewPacket.build(
               approval_task(row, ctx.tenant),
               [actor: fresh(ctx.lead), tenant: ctx.tenant],
               [:currency]
             ).currency ==
               {:unknown, :unreadable}
    end

    test "only an invocation's approval task asks, and a question is completed only by its answer",
         ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)
      assert {:ok, _} = door(:request_info, task, ctx.lead, %{question: "Which ward?"}, ctx)
      Execution.apply_invocation_decision!(row, oban(ctx.tenant))
      asked = info_task(row, ctx.tenant)

      # The information task is no approval: it cannot ask in turn, nor be approved.
      assert {:error, error} = door(:request_info, asked, ctx.nurse, %{question: "?"}, ctx)
      assert Exception.message(error) =~ "only a request waiting for approval"
      assert {:error, error} = door(:reject, asked, ctx.nurse, %{}, ctx)
      assert Exception.message(error) =~ "answer it"

      # A cancelled question is not an answer: the request does not move.
      task_set!(asked, status: "cancelled")

      assert {:error, _} = provide_info(committed(row.id, ctx.tenant), ctx)
      assert committed(row.id, ctx.tenant).status == :request_info
    end
  end

  describe "nothing but an approval makes a request ready" do
    test "a missing decision is refused and writes nothing", ctx do
      row = request!(ctx)
      assert {:error, _} = apply_decision(row, ctx)
      assert committed(row.id, ctx.tenant).status == :awaiting_approval
    end

    test "an unknown outcome on the task is never read as approved", ctx do
      row = request!(ctx)

      task_set!(approval_task(row, ctx.tenant), status: "completed", outcome: "maybe")

      assert {:error, _} = apply_decision(row, ctx)
      refute committed(row.id, ctx.tenant).status == :ready
    end

    test "an errored read of the decision is refused and writes nothing", ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)
      assert {:ok, _} = door(:approve, task, ctx.lead, %{}, ctx)

      AshEnterprise.Faults.arm(:invocation_decision_applying, :raise)

      attempt =
        try do
          apply_decision(row, ctx)
        rescue
          error -> {:raised, error}
        end

      refute match?({:ok, _}, attempt)
      assert committed(row.id, ctx.tenant).status == :awaiting_approval
    end

    test "a missing info task is never read as an answer", ctx do
      row = request!(ctx)
      task = approval_task(row, ctx.tenant)
      assert {:ok, _} = door(:request_info, task, ctx.lead, %{question: "Which ward?"}, ctx)
      Execution.apply_invocation_decision!(row, oban(ctx.tenant))

      # Filed under another key, the row has no information task to read.
      task_set!(info_task(row, ctx.tenant), node_id: "invocation.elsewhere")

      assert {:error, _} = provide_info(committed(row.id, ctx.tenant), ctx)
      assert committed(row.id, ctx.tenant).status == :request_info
    end
  end
end

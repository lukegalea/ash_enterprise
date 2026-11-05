defmodule AshEnterprise.Execution.ApprovalBindingTest do
  @moduledoc """
  Approval integrity (ADR 0055, "Approval binding"; invariant A): an approval binds the
  exact request it was asked for, and an invocation runs only while that approval still
  holds and its approver still may give it.

  A nurse asks to retitle one of their clinic notes through a target declared
  `approval: :four_eyes` by a clinic lead within four hours
  (`AshEnterprise.Test.Execution.ClinicNote.retitle_reviewed`). The request opens a
  standalone approval task for the clinic leads; a lead decides it through the existing
  `HumanTask.approve` door; the `:apply_decision` trigger applies it; the `:execute`
  job claims and runs it. Each test moves one thing between those steps and checks the
  row does not run under an approval that no longer fits.

  Durability tier: decisions, applications and claims commit for real, and the sweep
  runs on a real Oban. The `:execution` queue is paused so each test drives the steps
  itself, except where it resumes it to let the sweep work.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  require Ash.Query

  alias AshAgent.Invocation.{Executor, IdempotencyConflict}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Execution.Invocation.{ApplyDecisionScheduler, ApplyDecisionWorker}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.ClinicNote

  @retitle "AshEnterprise.Test.Execution.ClinicNote.retitle_reviewed"
  @record "AshEnterprise.Test.Execution.ClinicNote.record_approved"
  @lead_role "Clinic lead"

  setup do
    subscribe_jobs()
    pause_execution!()
    %{admin: admin, nurse: nurse, tenant: tenant} = clinic!()

    lead = DailyFixtures.member!(admin, @lead_role, [])
    second_lead = DailyFixtures.member!(admin, "Front desk #{unique()}", [])
    bystander = DailyFixtures.member!(admin, "Porter #{unique()}", [])
    grant_role!(second_lead, @lead_role, tenant)
    # The nurse holds the approver role too, so only four eyes keeps them out.
    grant_role!(nurse, @lead_role, tenant)

    note =
      Ash.create!(ClinicNote, %{title: "Ask the lab about the panel #{unique()}"},
        action: :record,
        actor: nurse.actor,
        tenant: tenant
      )

    %{
      admin: admin,
      nurse: nurse,
      lead: lead,
      second_lead: second_lead,
      bystander: bystander,
      note: note,
      tenant: tenant
    }
  end

  defp unique, do: System.unique_integer([:positive])

  defp grant_role!(person, role_name, tenant) do
    role =
      Security.Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: person.user.id,
        role_id: role.id,
        scoping_business_unit_id: person.user.owning_business_unit_id
      },
      actor: SystemActor.seed(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  defp revoke_role!(person, role_name, tenant) do
    user_id = person.user.id

    Security.UserRole
    |> Ash.Query.filter(user_id == ^user_id and role.name == ^role_name)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.each(&Ash.destroy!(&1, actor: SystemActor.seed(), tenant: tenant))
  end

  # A fresh actor: candidacy is precomputed when the context is built.
  defp fresh(person), do: DailyFixtures.actor(person.user)

  defp request!(ctx, title, key \\ nil) do
    {:ok, row} =
      invoke(
        ctx.nurse,
        @retitle,
        %{"id" => ctx.note.id, "title" => title},
        key || "retitle:#{unique()}"
      )

    row
  end

  # The same approval on a new note the nurse may write as themselves: the runs that
  # must succeed use it, since retitling needs a grant on notes nobody here holds.
  defp request_note!(ctx, title) do
    {:ok, row} = invoke(ctx.nurse, @record, %{"title" => title}, "record:#{unique()}")
    row
  end

  defp approval_task(row, tenant) do
    key = Approval.key()
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp decide(row, person, ctx, action \\ :approve) do
    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: approval_task(row, ctx.tenant).id},
      actor: fresh(person),
      tenant: ctx.tenant
    )
    |> Ash.run_action()
  end

  # What the `:apply_decision` worker runs, driven by hand.
  defp apply!(row, ctx), do: Execution.apply_invocation_decision!(row, oban(ctx.tenant))

  defp approved!(ctx, title) do
    row = request!(ctx, title)
    assert {:ok, _} = decide(row, ctx.lead, ctx)
    ready = apply!(row, ctx)
    assert ready.status == :ready
    ready
  end

  # Another write to the note, made outside the invocation: its version moves on.
  defp written_elsewhere!(ctx) do
    note = Ash.get!(ClinicNote, ctx.note.id, authorize?: false, tenant: ctx.tenant)

    note
    |> Ash.Changeset.for_update(:retitle, %{title: "Changed meanwhile #{unique()}"},
      authorize?: false,
      tenant: ctx.tenant
    )
    |> Ash.update!()
  end

  defp execute(row, ctx), do: Executor.execute(row.__struct__, row.id, oban(ctx.tenant))
  defp outcome(row, ctx), do: committed(row.id, ctx.tenant) |> Map.take([:status, :error_code])

  test "four eyes: the requester is no candidate; another lead approves, the trigger applies it, and it runs",
       ctx do
    row = request!(ctx, "Lab panel results to the chart #{unique()}")
    assert {row.status, row.approval_mode} == {:awaiting_approval, :four_eyes}

    # What the approval binds: RFC 9396 details and their JCS digest, with an expiry.
    assert [%{"type" => "urn:ash-agent:action:" <> @retitle, "identifier" => id}] =
             row.authorization_details

    assert id == ctx.note.id
    assert row.approval_digest == AshAgent.Digest.sha256_hex(row.authorization_details)
    assert DateTime.diff(row.approval_expires_at, DateTime.utc_now(), :minute) in 238..240

    task = approval_task(row, ctx.tenant)
    assert {task.status, task.instance_id} == {:open, nil}
    assert ctx.nurse.user.id in task.excluded_principal_ids

    # A candidate reads what they are asked to approve; nobody else does.
    assert {:ok, _} = Execution.get_invocation(row.id, actor: fresh(ctx.lead), tenant: ctx.tenant)

    assert {:error, _} =
             Execution.get_invocation(row.id, actor: fresh(ctx.bystander), tenant: ctx.tenant)

    # The requester holds the role and still cannot approve their own request.
    assert {:error, _} = decide(row, ctx.nurse, ctx)
    assert {:error, _} = decide(row, ctx.bystander, ctx)

    # The machinery cannot make up a decision: the outcome comes from the task.
    assert {:error, _} =
             Execution.apply_invocation_decision(
               row,
               %{outcome: :approved, decided_by_id: ctx.lead.user.id},
               oban(ctx.tenant)
             )

    assert committed(row.id, ctx.tenant).status == :awaiting_approval

    assert {:ok, _} = decide(row, ctx.second_lead, ctx)
    ready = apply!(row, ctx)

    assert {ready.status, ready.approved_by_id, ready.approval_task_id} ==
             {:ready, ctx.second_lead.user.id, task.id}

    # An approval that still holds runs.
    title = "Lab panel results filed #{unique()}"
    new = request_note!(ctx, title)
    assert {:ok, _} = decide(new, ctx.lead, ctx)
    assert apply!(new, ctx).status == :ready
    assert {:ok, :succeeded} = execute(new, ctx)
    assert effects(ctx.tenant, title) == 1
  end

  test "a rejection is applied as rejected, and nothing runs", ctx do
    title = "Cancel the interpreter #{unique()}"
    row = request!(ctx, title)
    assert {:ok, _} = decide(row, ctx.lead, ctx, :reject)

    rejected = apply!(row, ctx)
    assert {rejected.status, rejected.failure_class} == {:rejected, :rejected}
    assert effects(ctx.tenant, title) == 0
  end

  test "the subject changed while the approval was pending: stale, not ready (F4)", ctx do
    title = "Move the flu clinic #{unique()}"
    row = request!(ctx, title)
    written_elsewhere!(ctx)

    assert {:ok, _} = decide(row, ctx.lead, ctx)
    stale = apply!(row, ctx)

    assert {stale.status, stale.error_code, stale.approved_by_id} ==
             {:stale, "subject_changed", nil}

    assert effects(ctx.tenant, title) == 0
  end

  test "the subject changed after the approval: the claim finds it stale and nothing runs (F4)",
       ctx do
    title = "Rename the triage list #{unique()}"
    ready = approved!(ctx, title)
    written_elsewhere!(ctx)

    assert {:ok, :stale} = execute(ready, ctx)
    assert outcome(ready, ctx) == %{status: :stale, error_code: "subject_changed"}
    assert effects(ctx.tenant, title) == 0
  end

  test "the target is declared differently since the request: stale (F3)", ctx do
    title = "Reword the discharge note #{unique()}"
    row = request!(ctx, title)
    requested_under_earlier_definition!(row)
    assert {:ok, _} = decide(row, ctx.lead, ctx)

    stale = apply!(committed(row.id, ctx.tenant), ctx)
    assert {stale.status, stale.error_code} == {:stale, "target_changed"}
    assert effects(ctx.tenant, title) == 0
  end

  test "an approval expires: undecided, the trigger finds it stale; approved, the claim does",
       ctx do
    title = "Order the new thermometers #{unique()}"
    pending = request!(ctx, title)
    elapse!(pending, :approval_expires_at)

    # Undecided and past its expiry, the row is what the sweep selects.
    id = pending.id

    assert [%{id: ^id}] =
             Execution.Invocation
             |> Ash.Query.filter(
               id == ^id and status == :awaiting_approval and
                 (exists(approval_task, status in [:completed, :cancelled]) or
                    approval_expires_at <= now())
             )
             |> Ash.read!(oban(ctx.tenant))

    stale = apply!(committed(pending.id, ctx.tenant), ctx)
    assert {stale.status, stale.error_code} == {:stale, "approval_expired"}

    ready = approved!(ctx, title <> " again")
    elapse!(ready, :approval_expires_at)
    assert {:ok, :stale} = execute(ready, ctx)
    assert outcome(ready, ctx) == %{status: :stale, error_code: "approval_expired"}
    assert effects(ctx.tenant, title <> " again") == 0
  end

  test "the approver lost the approver role before the claim: stale, and nothing runs", ctx do
    title = "Swap the on-call nurse #{unique()}"
    ready = approved!(ctx, title)
    revoke_role!(ctx.lead, @lead_role, ctx.tenant)

    assert {:ok, :stale} = execute(ready, ctx)
    assert outcome(ready, ctx) == %{status: :stale, error_code: "approver_unauthorized"}
    assert effects(ctx.tenant, title) == 0
  end

  test "an approver deactivated before the claim no longer approves anything", ctx do
    title = "Reschedule the audit #{unique()}"
    ready = approved!(ctx, title)
    DailyFixtures.deactivate!(ctx.lead)

    assert {:ok, :stale} = execute(ready, ctx)
    assert outcome(ready, ctx) == %{status: :stale, error_code: "approver_unauthorized"}
  end

  test "an approved request does not cover changed arguments: a conflict under its key, a new approval under a new one (PLAT-05)",
       ctx do
    key = "retitle:#{unique()}"
    row = request!(ctx, "Book the lift repair #{unique()}", key)
    assert {:ok, _} = decide(row, ctx.lead, ctx)
    assert apply!(row, ctx).status == :ready

    changed = %{"id" => ctx.note.id, "title" => "Book the roof repair #{unique()}"}

    assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{}]}} =
             invoke(ctx.nurse, @retitle, changed, key)

    assert {:ok, again} = invoke(ctx.nurse, @retitle, changed, "retitle:#{unique()}")
    assert again.id != row.id
    assert {again.status, again.approved_by_id} == {:awaiting_approval, nil}
    assert again.approval_digest != row.approval_digest
  end

  test "a crash after the decision and before its application is healed by the sweep", ctx do
    title = "File the incident report #{unique()}"
    row = request_note!(ctx, title)
    assert {:ok, _} = decide(row, ctx.lead, ctx)

    # The worker applying it dies before it writes: nothing is applied.
    Faults.arm(:invocation_decision_applying, :raise)

    attempt =
      try do
        Execution.apply_invocation_decision(row, oban(ctx.tenant))
      rescue
        error -> {:raised, error}
      end

    refute match?({:ok, _}, attempt)

    assert committed(row.id, ctx.tenant).status == :awaiting_approval
    assert approval_task(row, ctx.tenant).status == :completed

    # The next sweep finds the decided task and applies it; the row then runs.
    Oban.resume_queue(queue: :execution)
    sweep = Oban.insert!(ApplyDecisionScheduler.new(%{}))
    await_job(sweep.id, :success)

    [applied] = jobs(row.id, ApplyDecisionWorker)
    await_job(applied.id, :success)
    [executed] = jobs(row.id)
    await_job(executed.id, :success)

    assert committed(row.id, ctx.tenant).status == :succeeded
    assert effects(ctx.tenant, title) == 1
  end

  describe "who may decide" do
    # Every way a call can arrive that is not a person's: each system actor and a bare
    # system context, with and without each engine's private flag, and each engine flag
    # with no actor at all.
    defp non_human_callers(tenant) do
      actors =
        Enum.map(SystemActor.all(), &{"system actor #{&1.name}", &1}) ++
          [{"bare system context", Security.ActorContext.system(tenant)}, {"no actor", nil}]

      flags = [
        {"", %{}},
        {" flagged by ash_bpmn", %{private: %{ash_bpmn?: true}}},
        {" flagged by ash_decisions", %{private: %{ash_decisions?: true}}}
      ]

      for {label, actor} <- actors, {flag, context} <- flags, do: {label <> flag, actor, context}
    end

    defp can_decide?(task, action, actor, context, tenant) do
      HumanTask
      |> Ash.ActionInput.for_action(action, %{record_id: task.id},
        actor: actor,
        tenant: tenant,
        context: context
      )
      |> Ash.can?(actor, tenant: tenant)
    end

    test "no system actor and no engine-flagged context can approve or reject; a candidate can",
         ctx do
      task = approval_task(request!(ctx, "Recall the courier #{unique()}"), ctx.tenant)

      for action <- [:approve, :reject, :resolve] do
        allowed =
          for {label, actor, context} <- non_human_callers(ctx.tenant),
              can_decide?(task, action, actor, context, ctx.tenant),
              do: label

        assert allowed == [], "#{action} reached by #{inspect(allowed)}"
      end

      assert can_decide?(task, :approve, fresh(ctx.lead), %{}, ctx.tenant)

      assert can_decide?(
               task,
               :approve,
               fresh(ctx.lead),
               %{private: %{ash_bpmn?: true}},
               ctx.tenant
             )
    end

    test "only the job runner applies a decision", ctx do
      row = request!(ctx, "Restock the gloves #{unique()}")

      callers =
        for {label, actor, context} <- non_human_callers(ctx.tenant),
            row
            |> Ash.Changeset.for_update(:apply_decision, %{},
              actor: actor,
              tenant: ctx.tenant,
              context: context
            )
            |> Ash.can?(actor, tenant: ctx.tenant),
            do: label

      assert callers == [
               "system actor oban",
               "system actor oban flagged by ash_bpmn",
               "system actor oban flagged by ash_decisions"
             ]

      refute Ash.can?({row, :apply_decision}, fresh(ctx.lead), tenant: ctx.tenant)
    end
  end
end

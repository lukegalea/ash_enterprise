defmodule AshEnterprise.Showcase.History do
  @moduledoc """
  The tour's fault-driven beats, run once in the demo tenant so that an instance whose fault
  panel is off still shows a real record of each failure (`mix ash_enterprise.demo
  --history`, decision P5-3).

  Each beat is the same thing the tour's buttons and the fault panel's controls do, through
  the application's own actions, in this process:

  | Beat | Failure | What happens | What it leaves |
  |---|---|---|---|
  | 3 | F4 | the coordinator asks; the credential is corrected; a committee member approves | the request `stale`, `subject_changed` |
  | 4 | F5 | the coordinator asks; their role is removed; approved; the role is given back | the request `failed`, `denied` |
  | 5 | F2 | the registry's answer is lost after it accepted, and it cannot say afterwards | the request `outcome_unknown`, a person asked to settle it |
  | 19 | F3 | the coordinator asks; a change to `activate_credential` is deployed; approved | the request `stale`, `manifest_changed` |
  | 7 | F1 | the model fails in the turn after the reader's lookups | the run with a failed model call, each lookup run once |
  | 11, 12 | F7, F6 | DEMO-PH-0006's case is opened; its document webhook is delivered twice | one check refused, one passed; one continuation |
  | 17 | F10 | a case is opened, the routing table changes, another is opened | two cases on two table versions |

  F2 and F1 arm fault points (`AshEnterprise.Faults`), which live in this node only, and
  disarm them when the beat ends, also when it fails. Their jobs, and every beat's, are held
  (`AshEnterprise.Showcase.History.HeldJobs`): no other node on the database runs them, and
  this process drains them itself. The F1 run is left waiting on its lease; the platform's
  own recover sweep finishes it when the lease runs out, on whichever node sweeps. F2 is the
  "answer lost" variant: the "worker killed" one is settled by the reconcile sweep asking
  the demo registry, whose memory is the node that took the activation, so its outcome would
  depend on which node swept. That variant stays the demo build's.

  Every beat is found before it is run (its request's or run's key, its case), so a second
  run changes nothing. Every beat's outcome is read back through the tour's own reads and
  reported, the one found as much as the one just run: a found record is `:already` only
  when it shows its failure. One that did not end in its failure, or a found one that does
  not show it (a case someone opened on the tour before the seed, a first run that was not
  produced), is `{:not_produced, observed}`, never reported as produced or recorded. With fault points compiled out, F1 and F2 are skipped and the
  others run.

  Only for the demo tenant (`AshEnterprise.Platform.DemoTenant.ensure_demo!/2`), after it
  is populated.
  """

  require Ash.Query

  alias AshBpmn.Triggers.SweepWorker
  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing

  alias AshEnterprise.Credentialing.{
    DemoData,
    DocumentWebhook,
    LicenceDemoData,
    ReleaseDemoData
  }

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.{DemoTenant, SystemActor}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Case, as: CaseTour
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Showcase.History.HeldJobs
  alias AshEnterprise.Showcase.Release, as: ReleaseTour

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"
  @prefix "clinic-demo:history:"
  @delivery "delivery:clinic-demo:history:f6"
  # A member of the credentialing committee (`DemoData`), who approves the requests.
  @member "kenji@example.com"

  @typedoc "One beat's line of the report."
  @type entry :: %{
          beat: pos_integer(),
          failures: [String.t()],
          status:
            :produced
            | :already
            | {:skipped, :fault_points_compiled_out}
            | {:not_produced, term()},
          ref: String.t() | nil
        }

  @doc "The key a beat's request or run is found by."
  @spec key(String.t()) :: String.t()
  def key(failure), do: @prefix <> String.downcase(failure)

  @doc "What every key the history makes starts with (`key/1`)."
  @spec key_prefix() :: String.t()
  def key_prefix, do: @prefix

  @doc """
  Runs the beats in `organization`, the populated demo tenant, and returns the report, one
  entry per beat, in the order they ran. Raises for any other organization before writing.

  `fault_points?:` says whether this build has fault points (default `Faults.enabled?/0`);
  without them the two beats that arm one are skipped.
  """
  @spec run!(Organization.t(), keyword()) :: [entry()]
  def run!(organization, opts \\ []) do
    DemoTenant.ensure_demo!(organization, "write history into")

    ctx =
      organization.id
      |> context()
      |> Map.put(:fault_points?, Keyword.get(opts, :fault_points?, Faults.enabled?()))

    HeldJobs.hold(fn ->
      report = [
        activation(ctx, 3, "F4", "DEMO-PT-0001", &correct/3, {:stale, "subject_changed"}),
        activation(ctx, 4, "F5", "DEMO-RN-0002", &revoke/3, {:failed, "denied"}),
        faulted(ctx, 5, "F2", &lost_answer/1),
        activation(ctx, 19, "F3", "DEMO-DT-0005", &deploy/3, {:stale, "manifest_changed"}),
        faulted(ctx, 7, "F1", &timeout/1),
        webhook(ctx),
        routing(ctx)
      ]

      HeldJobs.drain!()
      report
    end)
  end

  @doc "The beats a report covers, in the order they run."
  @spec beats() :: [pos_integer()]
  def beats, do: [3, 4, 5, 19, 7, 12, 17]

  @doc """
  Whether `report` puts every beat on record: each beat once, each produced now, found from
  an earlier run, or skipped because the fault points are compiled out. A beat missing, one
  not produced, or a status this module does not know reads as not complete.
  """
  @spec complete?(term()) :: boolean()
  def complete?(report) when is_list(report) do
    Enum.map(report, &beat_of/1) == beats() and Enum.all?(report, &on_record?/1)
  end

  def complete?(_report), do: false

  defp beat_of(%{beat: beat}), do: beat
  defp beat_of(_entry), do: nil

  defp on_record?(%{status: status}) when status in [:produced, :already], do: true
  defp on_record?(%{status: {:skipped, :fault_points_compiled_out}}), do: true
  defp on_record?(_entry), do: false

  # --- the people and records ---------------------------------------------------------

  defp context(tenant) do
    %{
      tenant: tenant,
      coordinator: LicenceDemoData.user!(DemoData.coordinator_email(), tenant),
      member: LicenceDemoData.user!(@member, tenant),
      director: LicenceDemoData.user!(LicenceDemoData.director_email(), tenant),
      oban: [actor: SystemActor.oban(), tenant: tenant]
    }
  end

  # A person's actor is built when it acts: an `ActorContext` is a snapshot of what its person
  # may do, and an approver may decide only a task that was open when it was built.
  defp as(user, tenant), do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp credential!(ctx, number) do
    [credential] =
      Credentialing.list_credentials!(
        actor: as(ctx.coordinator, ctx.tenant),
        tenant: ctx.tenant,
        query: [filter: [number: number]]
      )

    credential
  end

  # --- activation beats: ask, something changes, approve, run ------------------------

  defp activation(ctx, beat, failure, number, change, expected) do
    key = key(failure)

    case request(ctx, key) do
      %{} = row ->
        entry(beat, [failure], found(outcome(row, expected)), ref(:invocation, row.id))

      nil ->
        credential = credential!(ctx, number)
        row = ask!(ctx, credential, key)
        row = change.(ctx, credential, fn -> approve_and_run!(ctx, row) end)
        entry(beat, [failure], outcome(row, expected), ref(:invocation, row.id))
    end
  end

  defp request(ctx, key) do
    Execution.list_invocations!(
      authorize?: false,
      tenant: ctx.tenant,
      query: [filter: [invocation_key: key]]
    )
    |> List.first()
  end

  defp ask!(ctx, credential, key) do
    Execution.invoke!(
      @activate,
      %{"id" => credential.id},
      %{key: key},
      actor: as(ctx.coordinator, ctx.tenant),
      tenant: ctx.tenant
    )
  end

  # A committee member approves on the request's approval task, the decision is applied as
  # its job applies it, and the jobs that follow (the `:execute` job, a reconcile) run here.
  defp approve_and_run!(ctx, row) do
    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^row.id and node_id == ^Approval.key())
      |> Ash.read_one!(authorize?: false, tenant: ctx.tenant)

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: as(ctx.member, ctx.tenant),
      tenant: ctx.tenant
    )
    |> Ash.run_action!()

    Execution.apply_invocation_decision!(row, ctx.oban)
    HeldJobs.drain!()
    Execution.get_invocation!(row.id, authorize?: false, tenant: ctx.tenant)
  end

  defp correct(ctx, credential, run) do
    {:ok, _credential} = Tour.correct_expiry(credential.id, ctx.tenant)
    run.()
  end

  defp revoke(ctx, _credential, run) do
    {:ok, _count} = Tour.remove_coordinator_role(ctx.tenant)

    try do
      run.()
    after
      {:ok, _assignment} = Tour.restore_coordinator_role(ctx.tenant)
    end
  end

  defp deploy(ctx, _credential, run) do
    ReleaseDemoData.deploy_change!(ctx.tenant)
    run.()
  end

  defp outcome(%{status: status, error_code: code}, {status, code}), do: :produced

  defp outcome(%{status: :failed, failure_class: class}, {:failed, code}) when is_atom(class) do
    if to_string(class) == code, do: :produced, else: {:not_produced, {:failed, class}}
  end

  defp outcome(row, _expected), do: {:not_produced, {row.status, row.error_code}}

  # --- the two beats that arm a fault point -------------------------------------------

  defp faulted(%{fault_points?: true} = ctx, _beat, _failure, fun), do: fun.(ctx)

  defp faulted(_ctx, beat, failure, _fun),
    do: entry(beat, [failure], {:skipped, :fault_points_compiled_out}, nil)

  # F2: the registry's answer is lost after it accepted, and its lookup cannot answer.
  defp lost_answer(ctx) do
    key = key("F2")

    case request(ctx, key) do
      %{} = row ->
        entry(5, ["F2"], found(lost_answer_status(row)), ref(:invocation, row.id))

      nil ->
        credential = credential!(ctx, "DEMO-OT-0003")
        row = ask!(ctx, credential, key)
        quiet_window!()

        row =
          armed(Tour.lost_answer_points(), &Tour.arm_lost_answer/0, fn ->
            approve_and_run!(ctx, row)
          end)

        entry(5, ["F2"], lost_answer_status(row), ref(:invocation, row.id))
    end
  end

  defp lost_answer_status(row) do
    if row.status == :outcome_unknown and not is_nil(row.resolution_requested_at),
      do: :produced,
      else: {:not_produced, {row.status, row.error_code}}
  end

  # F1: the reader's model answers the turn that asks for the lookups and fails in the next.
  defp timeout(ctx) do
    key = key("F1")

    case Execution.get_agent_run_by_key(key,
           authorize?: false,
           tenant: ctx.tenant,
           not_found_error?: false
         ) do
      {:ok, %{} = run} ->
        entry(7, ["F1"], found(timeout_status(ctx, run)), ref(:run, run.id))

      _none ->
        credential = credential!(ctx, "DEMO-RN-0002")
        quiet_window!()

        {:ok, run} =
          armed([Tour.timeout_point()], &Tour.arm_model_timeout/0, fn ->
            {:ok, run} = Tour.start_reading(credential.id, as(ctx.coordinator, ctx.tenant), key)
            HeldJobs.drain!()
            {:ok, run}
          end)

        entry(7, ["F1"], timeout_status(ctx, run), ref(:run, run.id))
    end
  end

  # The run's first model call answered and the next failed, and each lookup ran once.
  defp timeout_status(ctx, run) do
    reading =
      ctx.coordinator
      |> as(ctx.tenant)
      |> Tour.readings()
      |> Enum.find(&(&1.run.id == run.id))

    case reading do
      nil ->
        {:not_produced, :run_not_read}

      reading ->
        calls = Enum.map(reading.model_calls, &to_string(&1.outcome))
        attempts = Enum.map(reading.lookups, & &1.attempt_count)

        if Enum.take(calls, 2) == ["ok", "error"] and attempts != [] and
             Enum.all?(attempts, &(&1 == 1)),
           do: :produced,
           else: {:not_produced, %{model_calls: calls, lookups: attempts}}
    end
  end

  defp armed(points, arm, fun) do
    :ok = arm.()

    try do
      fun.()
    after
      Enum.each(points, &Faults.disarm/1)
    end
  end

  # AshOban's minute sweeps on another node enqueue an `:execute` job for any `ready`
  # invocation and a `:step` job for any queued run. The row's own claim lets one node run
  # it, but if the other node's job won the claim the fault would not fire there. So a
  # faulted beat starts clear of a minute boundary: its critical section is well under a
  # second. The outcome is checked afterwards all the same.
  defp quiet_window! do
    second = DateTime.utc_now().second
    if second >= 50 or second < 5, do: Process.sleep(:timer.seconds(rem(65 - second, 60)))
    :ok
  end

  # --- the case beats ------------------------------------------------------------------

  # F7 and F6: DEMO-PH-0006 has no licence document, so its documents check is refused and
  # the case asks for one; the filing system's webhook then arrives twice.
  defp webhook(ctx) do
    credential = credential!(ctx, "DEMO-PH-0006")

    case case_of(ctx, credential) do
      %{} = row ->
        entry(
          12,
          ["F7", "F6"],
          found(webhook_status(row, nil)),
          ref(:process_instance, row.instance.id)
        )

      nil ->
        {:ok, _case} = CaseTour.open_case(credential.id, as(ctx.coordinator, ctx.tenant))
        HeldJobs.drain!()
        answers = for _ <- 1..2, do: DocumentWebhook.deliver(ctx.tenant, credential.id, @delivery)
        sweep!(ctx.tenant)
        row = case_of(ctx, credential)

        entry(
          12,
          ["F7", "F6"],
          webhook_status(row, answers),
          ref(:process_instance, row.instance.id)
        )
    end
  end

  # One check refused for the missing document and another passed (F7); the webhook's two
  # deliveries answered received then duplicate, and moved the case on once (F6). A case
  # found from an earlier run has no answers to read (`nil`): its record alone must show it.
  defp webhook_status(row, answers) do
    refused? =
      Enum.any?(
        row.checks,
        &(&1.status == :failed and &1.error_code == "licence_document_missing")
      ) and
        Enum.any?(row.checks, &(&1.status == :succeeded))

    once? =
      answers in [nil, [:received, :duplicate]] and length(row.deliveries) == 1 and
        row.continuations == 1

    if refused? and once?,
      do: :produced,
      else:
        {:not_produced,
         %{
           checks: Enum.map(row.checks, &{&1.status, &1.error_code}),
           answers: answers,
           deliveries: length(row.deliveries),
           continuations: row.continuations
         }}
  end

  # F10: a case opened before the routing table changes keeps the version it started under.
  defp routing(ctx) do
    older = credential!(ctx, "DEMO-DT-0005")
    newer = credential!(ctx, "DEMO-OT-0003")
    coordinator = as(ctx.coordinator, ctx.tenant)

    case case_of(ctx, newer) do
      %{} = row ->
        status = found(routing_status(ctx, case_of(ctx, older), row))
        entry(17, ["F10"], status, ref(:process_instance, row.instance.id))

      nil ->
        first = case_of(ctx, older) || open!(ctx, older, coordinator)

        if version(ctx, first) == active_version(ctx) do
          ReleaseDemoData.change_routing!(ctx.tenant)
        end

        second = open!(ctx, newer, coordinator)

        entry(
          17,
          ["F10"],
          routing_status(ctx, first, second),
          ref(:process_instance, second.instance.id)
        )
    end
  end

  # The older case is on an earlier table version than the newer one.
  defp routing_status(_ctx, nil, _second), do: {:not_produced, %{older: nil}}

  defp routing_status(ctx, first, second) do
    {before, now} = {version(ctx, first), version(ctx, second)}

    if is_integer(before) and is_integer(now) and before < now,
      do: :produced,
      else: {:not_produced, %{older: before, newer: now}}
  end

  # The process engine's sweep, which moves a waiting case on when its message has arrived,
  # run here as its cron job runs it (this node's Oban runs no plugin), then its jobs.
  defp sweep!(tenant) do
    :ok = SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    HeldJobs.drain!()
  end

  defp open!(ctx, credential, coordinator) do
    {:ok, _case} = CaseTour.open_case(credential.id, coordinator)
    HeldJobs.drain!()
    case_of(ctx, credential)
  end

  defp case_of(ctx, credential) do
    ctx.coordinator
    |> as(ctx.tenant)
    |> CaseTour.cases()
    |> Enum.find(&(&1.credential && &1.credential.id == credential.id))
  end

  defp version(ctx, row) do
    routing = ReleaseTour.read(as(ctx.director, ctx.tenant), [row]).routing
    Enum.find_value(routing.cases, &(&1.id == row.instance.id && &1.table_version))
  end

  defp active_version(ctx),
    do: ReleaseTour.read(as(ctx.director, ctx.tenant), []).routing.table_version

  # A beat found from an earlier run is on record only if its record shows the failure.
  defp found(:produced), do: :already
  defp found(not_produced), do: not_produced

  defp entry(beat, failures, status, ref),
    do: %{beat: beat, failures: failures, status: status, ref: ref}

  defp ref(type, id), do: "#{type}:#{id}"
end

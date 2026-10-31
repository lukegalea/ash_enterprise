# AshAgent triggers

The package ships no workers. Declare each trigger on your own resource; ash_oban generates the worker and the
scheduler.

## `:execute` on an invocation resource

`request` and `apply_decision` enqueue `:execute` for every row they make ready, inside their transaction, so a
committed ready row always has a job and a rolled-back row never does. The scheduler is the sweep that picks up a
ready row whose job was lost, so keep one.

```elixir
oban do
  triggers do
    trigger :execute do
      action :execute
      where expr(status == :ready and (is_nil(next_attempt_at) or next_attempt_at <= now()))
      read_action :read
      stream_with :full_read
      queue :execution
      scheduler_cron "* * * * *"
      max_attempts 3
      use_tenant_from_record? true
      actor_persister :none
      default_actor MyClinic.JobRunner.actor()
      worker_module_name MyClinic.Execution.Invocation.ExecuteWorker
      scheduler_module_name MyClinic.Execution.Invocation.ExecuteScheduler
    end
  end
end
```

## `:reconcile` on an invocation resource

`mark_outcome_unknown` enqueues it in its own transaction. Its scheduler is the sweep that finds rows whose lease
expired (a worker died) and dispatched rows whose deadline passed, which nothing enqueues.

```elixir
trigger :reconcile do
  action :reconcile
  where expr(
          (status == :executing and lease_expires_at <= now()) or
            (status == :dispatched and deadline_at <= now()) or
            (status == :outcome_unknown and is_nil(resolution_requested_at))
        )
  read_action :read
  stream_with :full_read
  queue :execution
  scheduler_cron "* * * * *"
  max_attempts 3
  use_tenant_from_record? true
  actor_persister :none
  default_actor MyClinic.JobRunner.actor()
  worker_module_name MyClinic.Execution.Invocation.ReconcileWorker
  scheduler_module_name MyClinic.Execution.Invocation.ReconcileScheduler
end
```

## Applying a person's resolution

`apply_resolution` is yours to trigger, like `apply_decision`: a trigger whose `where` says the task you opened for the
row has been decided, and a change on the action that sets `outcome` from it.

### Rules

1. **`action :execute`.** It is a generic action with no transaction: it claims in one transaction, runs the target,
   and completes in another, so no transaction is open while a target calls out. ash_oban does not re-check `where`
   before a generic action runs; the claim does, and a job for a row that is no longer ready ends as `:skipped`
   (or `:stale`, when its target changed since the request).
2. **`actor_persister :none`.** The job runs as the trigger's default actor, never as the requester. The actor the
   target runs as is rebuilt at claim by your `AshAgent.ExecutionIdentity`.
3. **`use_tenant_from_record? true`** on a multitenant resource, so each job runs in its row's tenant.
4. **Keep a `scheduler_cron`.** A trigger with `scheduler_cron false` has no scheduler and nothing sweeps it.
5. **`stream_with :full_read`**, because `where` depends on the time.
6. **Job arguments carry the row's id only**, which ash_oban does by default.
7. Give the default actor authority over the machinery actions (`claim`, `succeed`, `fail`, `defer`, `dispatch`,
   `mark_outcome_unknown`, `mark_stale`, `requeue`, `complete_external`, `request_resolution`, `apply_resolution`, `apply_decision`,
   `execute` and `reconcile`) and keep everyone else out of them; a person's grants should never reach them.
8. **`:reconcile` is not optional.** A host using AshOban must declare it: without it, a row whose worker died stays
   `executing` for good.

## `:step` and `:recover` on a run resource

`start`, every `record_step` that leaves a run queued or waiting, `recover`, and `AshAgent.Run.Changes.Wake` on the
invocation resource enqueue `:step` in their own transaction. Its scheduler is the sweep for a run whose wake-up was
lost. `:recover` queues again a run whose worker died holding the lease; nothing enqueues it but its sweep.

```elixir
oban do
  triggers do
    trigger :step do
      action :step
      where expr(needs_step)
      read_action :read
      queue :agents
      scheduler_cron "* * * * *"
      max_attempts 3
      use_tenant_from_record? true
      actor_persister :none
      default_actor MyClinic.JobRunner.actor()
      worker_module_name MyClinic.Execution.Run.StepWorker
      scheduler_module_name MyClinic.Execution.Run.StepScheduler
    end

    trigger :recover do
      action :recover
      where expr(status == :running and lease_expires_at <= now())
      read_action :read
      stream_with :full_read
      queue :agents
      scheduler_cron "* * * * *"
      max_attempts 3
      use_tenant_from_record? true
      actor_persister :none
      default_actor MyClinic.JobRunner.actor()
      worker_module_name MyClinic.Execution.Run.RecoverWorker
      scheduler_module_name MyClinic.Execution.Run.RecoverScheduler
    end
  end
end
```

### Rules for runs

1. **`action :step`** is a generic action with no transaction: the claim, each record and the model call between
   them are separate, so no transaction or row lock is held across the call. ash_oban does not re-check `where`
   before a generic action runs; the step reads the run with `needs_step` and claims it, and a job with nothing to do
   ends as `:skipped` without a model call.
2. **`:recover` keeps ash_oban's default lock**: it is a plain database transition.
3. The same rules as for invocations: `actor_persister :none`, `use_tenant_from_record? true`, a `scheduler_cron`
   kept on purpose, job arguments carrying the row's id only.

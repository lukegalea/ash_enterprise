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

### Rules

1. **`action :execute`.** It is a generic action with no transaction: it claims in one transaction, runs the target,
   and completes in another, so no transaction is open while a target calls out. ash_oban does not re-check `where`
   before a generic action runs; the claim does, and a job for a row that is no longer ready ends as `:skipped`.
2. **`actor_persister :none`.** The job runs as the trigger's default actor, never as the requester. The actor the
   target runs as is rebuilt at claim by your `AshAgent.ExecutionIdentity`.
3. **`use_tenant_from_record? true`** on a multitenant resource, so each job runs in its row's tenant.
4. **Keep a `scheduler_cron`.** A trigger with `scheduler_cron false` has no scheduler and nothing sweeps it.
5. **`stream_with :full_read`**, because `where` depends on the time.
6. **Job arguments carry the row's id only**, which ash_oban does by default.
7. Give the default actor authority over `claim`, `succeed`, `fail`, `apply_decision` and `execute` and keep everyone
   else out of them; a person's grants should never reach them.

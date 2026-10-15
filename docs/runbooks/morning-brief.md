# Runbook: the morning brief

The morning brief is the first thing on Today (`/app/today`, ACP `today`): the
day's calendar as a short draft, waiting for you to approve or reject it. It is
a `MorningBrief` row carried through the `morning.brief` BPMN process
(`priv/bpmn/morning_brief.bpmn`): compose the draft (a fixed template, no LLM),
open an approval task on the brief's owner, then record the decision.

## When briefs are composed

Every day from **06:30 on the display zone's clock** (`DISPLAY_TIME_ZONE`,
default `America/Toronto`). Anyone who owns an active, unblocked Google Calendar
linked account gets one. A sync-blocked account is skipped until it is
unblocked (Accounts & syncs).

`AshEnterprise.Agents.MorningBriefScheduler` runs every 15 minutes in UTC. Before
06:30 local it does nothing. After that it enqueues one compose job per calendar
owner per day. The ticks after the first collapse into the existing job. The job
composes as the owner, under the owner's policies.

Because it checks the clock on every tick instead of running once at 06:30:

- daylight saving changes nothing;
- `DISPLAY_TIME_ZONE` takes effect at the next restart;
- a server that was down at 06:30 composes the day's brief on its first tick
  after it comes back (any time before midnight). It does not compose the
  days it missed.

To change the hour, set `config :ash_enterprise, :morning_brief_compose_at` (a
`Time`). It is checked on every tick.

The draft lists the events that were synced when the brief was composed. An
event synced later in the day is not added. The brief's text is rendered when
it is read, so a renamed event shows its new title, and a shredded scope shows
`[shredded]`.

## Composing one now

You get one brief per person per day. Once today has a brief, it cannot be
recomposed, whether it is approved, rejected or still waiting. The process has
no path from its approval task back to its compose step.

- **Web:** Today shows **Compose today's brief** while you have no brief for
  the day.
- **amber (ACP):** `brief` or `compose brief`. If today has no brief, a
  permission modal asks first, and the brief is composed once you allow it. If
  today already has one, you get the Today digest instead.
- **IEx, in the running node:**

  ```elixir
  alias AshEnterprise.Security.ActorContext
  user = AshEnterprise.Accounts.get_user_by_email!("you@example.com", authorize?: false)
  actor = ActorContext.attach(user, ActorContext.build(user))
  AshEnterprise.Agents.MorningBrief.compose_today(actor: actor, tenant: ActorContext.tenant(actor))
  ```

Approve or reject on Today, in Approvals, or with `approve brief` / `reject brief`
in amber.

## Which process runs

`AshEnterprise.Process.Resolver` decides. A tenant's own bound copy of
`morning.brief` runs if the tenant has one. Otherwise the platform baseline
runs, and that baseline is published by `mix ash_enterprise.bpmn.publish`. A
tenant needs nothing set up to run the baseline. The brief is started directly
from the action, not through an event subscription, so the subscription lane's
in-tenant-only lookup does not apply (see `AshEnterprise.Process`).

If compose fails with `no published morning.brief process`, run
`mix ash_enterprise.bpmn.publish`.

## Checking on it

The compose jobs are Oban jobs for `AshEnterprise.Agents.MorningBriefWorker`,
one per calendar owner per day. A job that cancels with `:user_inactive` or
`:forbidden_by_policy` is not retried. Once the cause is fixed, compose that
day's brief on demand.

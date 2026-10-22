# Time travel (PROD-47, E8.4)

The dogfood app can show what it knew at any instant for the two resources that were already temporal:
who a golden person resolved to (`AshEnterprise.Mdm.SourceIdentity`) and what System One knew about a
subject (`AshEnterprise.SystemOne.Fact`), and, since the second slice, the calendar
(`AshEnterprise.Canonical.CalendarEvent`). This page records what each slice built, how the read path
works, and which resources should become temporal next.

## What is built (2026-10-21)

| Piece | Where | Proven by |
|---|---|---|
| `?as_of=` grammar, view-only pinned surfaces, `time_travel: true` on `LiveRenderer`, the scrubber | ash_a2ui (`AshA2ui.AsOf`, `AshA2ui.TimeScrubber`, `:as_of` on `Info` and `ActionHandler`) | ash_a2ui `test/time_travel_test.exs`, `test/time_travel_live_test.exs` |
| Every version of a temporal record, through as-of reads | `AshEnterprise.Platform.TemporalHistory` | the two suites below |
| Who a person resolved to, and when | `AshEnterprise.Mdm.Resolution` | `test/ash_enterprise/mdm/resolution_test.exs` |
| What was true about a subject at T | `AshEnterprise.SystemOne.FactHistory` | `test/ash_enterprise/system_one/fact_history_test.exs` |
| The Time travel app (`/app/time-travel`, a person, a subject) | `AshEnterpriseWeb.TimeTravelLive` | `test/ash_enterprise_web/time_travel_live_test.exs` |
| Golden records at an instant (`/app/mdm/golden?as_of=`) | `AshEnterpriseWeb.A2uiLive.MdmGolden` | same LiveView suite |
| "As of last Friday" in the agent chat | `as_of` on the `find_people` tool | `test/ash_enterprise/assistant/lookup_test.exs`, eval case `resolved_last_friday` |

## Slice 2: the calendar (2026-10-22)

`AshEnterprise.Canonical.CalendarEvent` is temporal. "What did my week look like last Monday, before the
reschedules?" is `/app/calendar?week=<a date in that week>&as_of=<last Monday>`.

| Piece | Where | Proven by |
|---|---|---|
| The resource, its key and identities, each existing row's first version | `CalendarEvent`'s `temporal` block; `CalendarEvent.TemporalCutover` (custom statements); migration `20261022161918` | `test/ash_enterprise/canonical/calendar_time_travel_test.exs` |
| A write that changes nothing opens no version | `Canonical.Changes.KeepUnchangedVersion` | same suite |
| Agenda windows cut around the read's instant | `Preparations.AgendaWindow`, `LocalTime.window/2` | same suite |
| A week's reschedules and cancellations as marks | `Canonical.CalendarHistory` | same suite |
| The calendar at `?as_of=`, `?week=`, the scrubber | `AshEnterpriseWeb.DailyLive.Calendar` (`calendar_live.ex`) | `test/ash_enterprise_web/live/calendar_time_travel_live_test.exs` |
| "What was on my calendar last Monday, as of Friday" | `as_of` on the `calendar_events` tool | `lookup_test.exs`, eval case `calendar_as_of` |

What the risks in the table below turned out to be:

- **The upsert splits.** ash_postgres's temporal upsert (its `upsert_all/6`) splits the version
  valid at the write's instant and keeps the part before it, so a reschedule keeps the old time. Two things it does
  not do, which the host now does for it:
  - it does not refresh update defaults on a match, unlike the plain upsert (`touch_update_defaults?`), so a new
    version kept the first write's `updated_at`, and its business event the wrong `occurred_at`. `upsert_fields`
    names `:updated_at` and `:modified_on`;
  - it splits on every match, even when nothing changed, and Google reports events for changes this model does not
    project. `KeepUnchangedVersion` compares the projected values (the sealed ones in the clear) inside the write's
    transaction and returns the current version instead (`Ash.Changeset.set_result/2`); the attendee and
    business-event hooks still run against it.
- **The migration generator converts nothing.** On an existing table it adds `valid_at` and drops the foreign keys
  that touch the table, and leaves the plain `(id)` key and the plain unique identity indexes, both of which refuse an
  event's second version. `TemporalCutover` does the rest as custom statements, so codegen still emits the migration:
  each row's period from its `inserted_at`, `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`, the identities as
  `EXCLUDE USING gist (…, valid_at WITH &&)` under the generator's own names, and the foreign keys to
  `erasure_scopes` and `canonical_people` put back (a key from a temporal table to an ordinary one is enforceable; only
  one pointing *at* a temporal table is not). `EventAttendee.event_id` loses its foreign key: `id` alone is no longer
  unique. Nothing destroys events, so the lost `ON DELETE CASCADE` cascaded nothing.
- **Hooks.** `DeriveAttendees`, `SealUnderScope` and `BusinessEvents.Changes.Derive` declare `temporal_safe?/1`,
  each with its reasoning in its moduledoc: no clock, reads through Ash, and nothing whose meaning depends on the
  instant (a scope's key is the same for its whole life). `AshCloak`'s own change finds nothing to do, because
  `SealUnderScope` has already sealed the arguments.
- **AgendaWindow** cuts "today" around `query.as_of`. Read now, the instant is the clock.
- **Erasure.** Every version is sealed under the one scope key, so a shred reaches all of them; the suite reads each
  version's ciphertext before and after. A shredded event's times stay readable, version by version, which
  `docs/runbooks/crypto-shredding.md` now says.

What is not temporal shows today's values, and the calendar page says so: who is invited (`EventAttendee`), and
people's names.

### Deferred

- **The grid's "today".** ash_a2ui's calendar takes "today" from the wall clock (`AshA2ui.Calendar.today/0`): its
  default window, the Today button and the quick ranges' `calendar_anchor`. The page passes the week, so the grid
  opens where it should; a quick range clicked while pinned lists that range as of the instant (the read is
  `AgendaWindow`'s) but moves the grid to the real today. Threading `as_of` into `AshA2ui.Calendar` is a small
  ash_a2ui change.
- **Attendance history.** `EventAttendee` is not temporal, so who was invited, and how they answered, is today's.
- **Versions from before the cutover.** An event rewritten before the migration carries its current values back to
  its `inserted_at`. The ledger's `calendar_event.changed` facts hold the earlier times and statuses, if a backfill
  of those versions is ever wanted.

## How the read path works

- **One instant per read.** Ash has no "all of history" read. A version's period is `[lower, upper)`, so
  `TemporalHistory` finds the version before by reading a microsecond before `lower`, and the one after by
  reading at `upper`. Each step is an ordinary read as the caller, so policies decide every version.
- **Which identities.** `Resolution` starts from the person, read as the caller. A person the caller
  cannot read has no history. It walks the identities on that person, on the people merged into them, on
  the golden that absorbed them, and on the people their match candidates paired with them. That last
  source is how an identity that was merged in and then unmerged out is still found. Only identities that
  pointed at the person at some instant are kept.
- **Marks.** Each identity's first version is "Resolved"; a move to a golden it had not pointed at before
  is "Merged"; a move back is "Unmerged". Moves within five seconds with the same kind and the same two
  people are one moment, and the mark sits at the last of them, so landing on it shows the finished merge.
  The person's business events (a message arrived, a meeting they organize moved) are context marks.
  The ledger does not record merges; those come from the identities.
- **The actor.** `User` is not temporal, so the actor loaded for the request decides what the past shows.
  Everything here only reads (ADR 0049 invariant 7).
- **What is not temporal shows today's values.** Person names and merged flags are current. The pages
  say so.

## Which resources should become temporal next

Each of these is its own migration decision, and each needs the temporal-safety audit that ADR 0049
invariant 4 requires before it moves. CalendarEvent is done (slice 2, above); the others are not.

| Resource | Recommendation | What it would answer | What has to change first |
|---|---|---|---|
| `AshEnterprise.Canonical.CalendarEvent` | **Yes, first.** | "What did my week look like last Monday, before the reschedules?" | `upsert_from_source` is an upsert on `unique_external`: confirm ash_postgres's temporal upsert splits a version rather than overwriting it, and that the identity becomes `WITHOUT OVERLAPS`. `DeriveAttendees`, `SealUnderScope` and `BusinessEvents.Changes.Derive` run hooks and must be refactored into modules declaring `temporal_safe?/1`. `AgendaWindow` reads the window from the wall clock (`LocalTime.window/1`); it must read `query.as_of`, or every past agenda reads empty (clinic-demo hit this on its board). Erasure should be unaffected, since every version's ciphertext is sealed under the same scope key, but a shred test over a versioned row has to show it. |
| `AshEnterprise.Canonical.Task` (action items) | **Yes, after CalendarEvent.** | "What was open on my list last Friday?" | The same upsert question. `:capture` and `:complete` use only built-in changes; `:complete_mine` is a generic action that calls `:complete` and needs checking. The `:reassess_judgments` AshOban trigger reads current rows, which is what it should keep doing. Coordinate with PROD-18, which is changing action items now. |
| `AshEnterprise.Agents.MorningBrief` | **No, for now.** | "What did the brief say on the 14th?" | A brief is already one row per owner per day (`one_per_owner_per_day`), so its history is the rows themselves. What changes is its status (draft, approved, rejected), which the audit log records. Revisit only if a brief is ever regenerated in place. |

The order follows value over cost: CalendarEvent answers the question people ask most and carries the
most rewiring; Task is cheap once the upsert path is proven on CalendarEvent.

## Deferred

- **French copy.** HOUSE-STYLE HS-9 asks for English and French interface copy. This application ships
  English only today, and the new pages follow it.
- **Fact time travel in the agent chat.** No chat tool reads System One facts yet, so there was nothing
  to give `as_of`.
- **Merges in the ledger.** Merges are marks from the identity history, not business events. Recording
  them in the ledger would need a decision on what a merge is as a business fact.
- **Finance (E7.7)** is out of scope.

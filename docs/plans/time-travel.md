# Time travel (PROD-47, E8.4)

The dogfood app can show what it knew at any instant for the two resources that were already temporal:
who a golden person resolved to (`AshEnterprise.Mdm.SourceIdentity`) and what System One knew about a
subject (`AshEnterprise.SystemOne.Fact`). This page records what the first slice built, how the read path
works, and which resources should become temporal next. Nothing in the last section is built.

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

Each of these is its own migration decision. None of them is done, and each needs the temporal-safety
audit that ADR 0049 invariant 4 requires before it moves.

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

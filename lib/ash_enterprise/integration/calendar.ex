defmodule AshEnterprise.Integration.Calendar do
  @moduledoc """
  The Google Calendar vertical (epic E4, dogfood §11): an incremental sync of
  every calendar on a linked account's calendar list, landed through
  `AshEnterprise.Integration.Landing` and projected into
  `AshEnterprise.Canonical.CalendarEvent` / `Person` by
  `AshEnterprise.Canonical.Projections.Calendar`.

  ## The shape

    * `AshEnterprise.Integration.Calendar.Sync` — the entry points, as generic
      actions: `request_sync` (enqueue), `run_step` (one bounded step, run as
      the account's owner) and `reset_sync` (the explicit sync-reset).
    * `AshEnterprise.Integration.Calendar.SyncCursor` — one row per (linked
      account, calendar): the Google `syncToken` of the last completed pass and
      the `pageToken` of an in-flight one.
    * `AshEnterprise.Integration.Calendar.SyncWorker` — the Oban job, one per
      linked account, ids-only args.
    * `AshEnterprise.Integration.Calendar.Step` — the algorithm the `run_step`
      action runs.

  Every provider call is `AshEnterprise.Integration.GoogleCalendar`'s generated
  action, called as the human who owns the linked account: the Nango connection
  is resolved inside that action and never appears here.

  ## Why a domain of its own

  The edge's `AshEnterprise.Integration` domain is owned by another change, so
  this vertical carries its own until the integration step folds
  `SyncCursor` and `Sync` into it. `validate_config_inclusion?: false` is
  temporary for the same reason the edge's is.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Integration.Calendar.SyncCursor
    resource AshEnterprise.Integration.Calendar.Sync
  end
end

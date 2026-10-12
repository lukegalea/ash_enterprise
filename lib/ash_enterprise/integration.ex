defmodule AshEnterprise.Integration do
  @moduledoc """
  The provider edge (ADR 0011, AST-155 exercised in epic E4) and the three
  verticals built on it: outbound calls to third-party APIs through Nango's
  proxy, each one an ordinary Ash action, and the syncs that land what they
  fetch.

  ## The edge

    * `AshEnterprise.Integration.LinkedAccount` maps one of an actor's own
      provider accounts to a Nango connection. It is the only place a Nango
      connection id lives.
    * `AshEnterprise.Integration.GoogleCalendar`, `.Gmail` and `.Slack` are
      operation resources. Each declares its provider operations with the
      `AshEnterprise.Integration.Nango.Operations` DSL, and each declared
      operation becomes **one generic action** — policy-gated, traced and
      correlated like any other action. There is no integration log.
    * `AshEnterprise.Integration.Nango.Proxy` is the one module that speaks HTTP
      to Nango (Iron Law #20).
    * `AshEnterprise.Integration.Landing` is the one call an adapter makes to
      land a fetched record, sealed under the linked account's erasure scope
      (ADR 0024; `AshEnterprise.Integration.Landing.Scoped`).

  ## The verticals

    * Google Calendar — `Calendar.Sync` (entry points), `Calendar.SyncCursor`
      (per-calendar sync and page tokens), `Calendar.SyncWorker`,
      `Calendar.Step`; projected by `AshEnterprise.Canonical.Projections.Calendar`.
    * Gmail — `Gmail.SyncState` (historyId cursor), `Gmail.SyncWorker`,
      `Gmail.Sync`; projected (zone-gated, deny by default) by
      `AshEnterprise.Canonical.Projections.Gmail`.
    * Slack — `Slack.Sync` (entry points), `Slack.ConversationCursor`,
      `Slack.KnownMember`, `Slack.SyncWorker`, `Slack.Syncer`; projected
      (zone-gated, deny by default) by `AshEnterprise.Canonical.Projections.Slack`.
    * Gmail and Slack project what a step landed at the end of that step
      (`AshEnterprise.Canonical.Projections.Pending`), keeping their position
      in `AshEnterprise.Integration.ProjectionCursor`.
    * `AshEnterprise.Integration.SyncScheduler` enqueues one step per active
      linked account per vertical, on a cron.

  ## The rule that does not bend

  **The connection id is never an action argument.** It is resolved inside the
  action from the actor's own linked accounts (ADR 0011, dogfood deviation 1:
  per-user, not per-tenant). An adapter that holds several linked accounts for
  one provider names *which* by `linked_account_id` — a row the actor must own,
  read under the actor's policies — never by connection.

  ## Tier 3

  Removable by deletion: nothing in `accounts/`, `security/` or `audit/` imports
  this directory.
  """

  use Ash.Domain

  resources do
    resource AshEnterprise.Integration.LinkedAccount
    resource AshEnterprise.Integration.GoogleCalendar
    resource AshEnterprise.Integration.Gmail
    resource AshEnterprise.Integration.Slack

    resource AshEnterprise.Integration.Calendar.SyncCursor
    resource AshEnterprise.Integration.Calendar.Sync

    resource AshEnterprise.Integration.Gmail.SyncState

    resource AshEnterprise.Integration.Slack.Sync
    resource AshEnterprise.Integration.Slack.ConversationCursor
    resource AshEnterprise.Integration.Slack.KnownMember

    resource AshEnterprise.Integration.ProjectionCursor
  end
end

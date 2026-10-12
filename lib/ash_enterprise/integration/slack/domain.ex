defmodule AshEnterprise.Integration.Slack.Domain do
  @moduledoc """
  The Slack vertical's adapter (epic E4, PROD-5): an incremental, poll-only
  sync of the operator's Slack workspace through the provider edge
  (`AshEnterprise.Integration.Slack`), landing every fetched object through
  `AshEnterprise.Integration.Landing.land/2` under the linked account's scope.

    * `AshEnterprise.Integration.Slack.Sync` — the entry points: request a sync
      (enqueues `SyncWorker`) or run one step inline, as the acting human.
    * `AshEnterprise.Integration.Slack.ConversationCursor` — per-conversation
      sync position (ids and `ts` values only, never content).
    * `AshEnterprise.Integration.Slack.KnownMember` — which members' profiles
      were fetched, and when, so `users.info` is not re-spent every step.
    * `AshEnterprise.Integration.Slack.Syncer` — one sync step.
    * `AshEnterprise.Integration.Slack.SyncWorker` — the Oban job, one per
      linked account.

  A domain of its own only because the edge's `AshEnterprise.Integration`
  domain is owned by a concurrent change; folding these resources into it is an
  integration step. Tier 3 like the edge: removable by deletion.

  `validate_config_inclusion?: false` for the same reason as the edge's domain:
  `config :ash_enterprise, :ash_domains` is owned by a concurrent change.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Integration.Slack.Sync
    resource AshEnterprise.Integration.Slack.ConversationCursor
    resource AshEnterprise.Integration.Slack.KnownMember
  end
end

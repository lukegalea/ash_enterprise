defmodule AshEnterprise.Integration.Slack do
  @moduledoc """
  Slack Web API operations, proxied through the `slack` Nango integration
  (provider base URL `https://slack.com/api`). The connection holds a **user**
  token (`channels/groups/im/mpim :history + :read`, `users:read`); there is no
  bot.

    * `user_conversations` — `users.conversations`: only the conversations the
      token's user is a member of (joined public and private channels, MPIMs,
      IMs). Body: `ok`, `channels`, `response_metadata.next_cursor` (empty
      string on the last page). Items do not carry `is_member` — membership is
      what the endpoint selects on. `conversations.list` is deliberately not
      declared: with a user token it lists every public channel in the
      workspace, joined or not, so a member-only sync over it has to page
      through the whole workspace to find the user's own channels.
    * `conversation_history` — `conversations.history`. Body: `ok`,
      `messages`, `has_more`, `response_metadata.next_cursor`. `oldest` is a
      Slack `ts` string (`"1712345678.000100"`), the incremental cursor.
    * `user_info` — `users.info`. Body: `ok`, `user`.

  Slack reports most failures as `200 {"ok": false, "error": code}`; the
  `:slack` error profile maps those codes to `ProxyError` reasons
  (`invalid_auth` → `:unauthorized`, `channel_not_found` → `:not_found`,
  `ratelimited` → `:rate_limited`, `invalid_cursor` → `:gone`).

  VendorPM workspace content lands only sealed under the linked account's
  erasure scope (ADR 0024, `AshEnterprise.Integration.Landing`), so one shred
  forgets it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    extensions: [AshEnterprise.Integration.Nango.Operations]

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check for stored resources.
  resource do
    require_primary_key? false
  end

  nango do
    integration "slack"
    errors :slack

    operation :user_conversations, :get, "/users.conversations" do
      description "users.conversations: the channels, private groups, DMs and MPIMs the user is a member of."
      param :cursor, :string
      param :limit, :integer, constraints: [min: 1, max: 1000]

      param :types, :string,
        description:
          "e.g. public_channel,private_channel,mpim,im (Slack's default is public_channel only)"

      param :exclude_archived, :boolean
    end

    operation :conversation_history, :get, "/conversations.history" do
      description "conversations.history: messages in one conversation, newest first."
      param :channel, :string, allow_nil?: false
      param :cursor, :string
      param :oldest, :string
      param :latest, :string
      param :inclusive, :boolean
      param :limit, :integer, constraints: [min: 1, max: 999]
    end

    operation :user_info, :get, "/users.info" do
      description "users.info: one workspace member."
      param :user, :string, allow_nil?: false
    end
  end
end

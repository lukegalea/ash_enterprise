defmodule AshEnterprise.Integration.Slack do
  @moduledoc """
  Slack Web API operations, proxied through the `slack` Nango integration
  (provider base URL `https://slack.com/api`). The connection holds a **user**
  token (`channels/groups/im/mpim :history + :read`, `users:read`); there is no
  bot.

    * `list_conversations` — `conversations.list`. Body: `ok`, `channels`,
      `response_metadata.next_cursor` (empty string on the last page).
    * `conversation_history` — `conversations.history`. Body: `ok`,
      `messages`, `has_more`, `response_metadata.next_cursor`. `oldest` is a
      Slack `ts` string (`"1712345678.000100"`), the incremental cursor.
    * `user_info` — `users.info`. Body: `ok`, `user`.

  Slack reports most failures as `200 {"ok": false, "error": code}`; the
  `:slack` error profile maps those codes to `ProxyError` reasons
  (`invalid_auth` → `:unauthorized`, `channel_not_found` → `:not_found`,
  `ratelimited` → `:rate_limited`, `invalid_cursor` → `:gone`).

  VendorPM workspace content may not land anywhere until crypto-shredding
  (ADR 0024) is on main; `AshEnterprise.Integration.Landing` refuses by default.
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

    operation :list_conversations, :get, "/conversations.list" do
      description "conversations.list: channels, private groups, DMs and MPIMs visible to the user."
      param :cursor, :string
      param :limit, :integer, constraints: [min: 1, max: 1000]
      param :types, :string, description: "e.g. public_channel,private_channel,mpim,im"
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

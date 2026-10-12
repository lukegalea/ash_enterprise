defmodule AshEnterprise.Integration.Gmail.MessageList do
  @moduledoc """
  `users.messages.list`, proxied through the `google-mail` Nango integration:
  the one Gmail operation the bounded bootstrap backfill needs that
  `AshEnterprise.Integration.Gmail` does not declare.

    * `list_messages` — body: `messages` (`[%{"id", "threadId"}]`, may be
      absent), `nextPageToken`, `resultSizeEstimate`. Ids only; content is
      fetched per message with `Gmail.get_message`.

  Declared with the edge's DSL so it is an ordinary generated action: the
  connection is resolved from the actor's own linked account, never named.

  Interim home. The operation belongs in `AshEnterprise.Integration.Gmail`'s
  `nango` block (one operation resource per provider, one grant); moving it
  there and deleting this module is an integration step.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration.Gmail.SyncDomain,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    extensions: [AshEnterprise.Integration.Nango.Operations]

  # Same reason as the edge's operation resources: generic actions only, no
  # rows, but the platform's system attributes trip the primary-key check.
  resource do
    require_primary_key? false
  end

  nango do
    integration "google-mail"
    errors :google

    operation :list_messages, :get, "/gmail/v1/users/me/messages" do
      description "users.messages.list: message ids matching a query, newest first."
      param :q, :string
      param :page_token, :string, as: "pageToken"
      param :max_results, :integer, as: "maxResults", constraints: [min: 1, max: 500]
      param :label_ids, {:array, :string}, as: "labelIds"
      param :include_spam_trash, :boolean, as: "includeSpamTrash"
    end
  end
end

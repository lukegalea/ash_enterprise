defmodule AshEnterprise.Integration.Gmail do
  @moduledoc """
  Gmail API v1 operations, proxied through the `google-mail` Nango integration
  (provider base URL `https://gmail.googleapis.com`).

    * `get_profile` — `users.getProfile`. Body: `emailAddress`,
      `messagesTotal`, `threadsTotal`, `historyId` (the cursor to start
      `list_history` from).
    * `list_history` — `users.history.list`. Body: `history` (may be absent),
      `nextPageToken`, `historyId`. A `start_history_id` older than Gmail
      retains returns **404**, surfaced as `:not_found`: the adapter's cue to
      reset the cursor (`get_profile` for a fresh `historyId`).
    * `get_message` — `users.messages.get`. `format` is `:metadata` (default;
      headers only, narrowed by `metadata_headers`) or `:full`.

  Message content is personal data under ADR 0042; what an adapter does with
  the body it gets back is gated by zone admission and scoped landing, not here.
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
    integration "google-mail"
    errors :google

    operation :get_profile, :get, "/gmail/v1/users/me/profile" do
      description "users.getProfile: the mailbox address and its current historyId."
    end

    operation :list_history, :get, "/gmail/v1/users/me/history" do
      description "users.history.list: mailbox changes since a historyId."
      param :start_history_id, :string, as: "startHistoryId", allow_nil?: false
      param :page_token, :string, as: "pageToken"
      param :max_results, :integer, as: "maxResults", constraints: [min: 1, max: 500]
      param :label_id, :string, as: "labelId"

      param :history_types, {:array, :atom},
        as: "historyTypes",
        constraints: [
          items: [one_of: [:messageAdded, :messageDeleted, :labelAdded, :labelRemoved]]
        ]
    end

    operation :get_message, :get, "/gmail/v1/users/me/messages/{id}" do
      description "users.messages.get: one message, as metadata (default) or in full."
      param :id, :string, in: :path, allow_nil?: false

      param :format, :atom,
        default: :metadata,
        allow_nil?: false,
        constraints: [one_of: [:metadata, :full]]

      param :metadata_headers, {:array, :string}, as: "metadataHeaders"
    end
  end
end

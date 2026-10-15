defmodule AshEnterprise.Integration.GoogleCalendar do
  @moduledoc """
  Google Calendar API v3 operations, proxied through the `google-calendar`
  Nango integration (provider base URL `https://www.googleapis.com`).

  Each `operation` below is one generic action returning the decoded response
  body. Shapes follow Google's public reference:

    * `list_calendars` — `calendarList.list`. Body: `items`, `nextPageToken`,
      `nextSyncToken` (on the last page).
    * `list_events` — `events.list`. Body: `items`, `nextPageToken`,
      `nextSyncToken`. An expired `sync_token` returns **410**, surfaced as
      `ProxyError` reason `:gone`: the adapter calls its explicit sync-reset
      action and re-syncs from scratch. Google forbids combining `sync_token`
      with `time_min`/`time_max`; that is the caller's contract.

  No table: an operation resource holds actions, not rows. Ownership `:none`
  makes the policy question "may this actor call Calendar at all", answered by
  a global read grant on this resource.
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
    integration "google-calendar"
    errors :google

    operation :list_calendars, :get, "/calendar/v3/users/me/calendarList" do
      description "calendarList.list: the calendars on the actor's calendar list."
      param :page_token, :string, as: "pageToken"
      param :sync_token, :string, as: "syncToken"
      param :max_results, :integer, as: "maxResults", constraints: [min: 1, max: 250]
      param :show_deleted, :boolean, as: "showDeleted"
    end

    operation :list_events, :get, "/calendar/v3/calendars/{calendar_id}/events" do
      description "events.list: events on one calendar, incrementally via sync tokens."
      param :calendar_id, :string, in: :path, allow_nil?: false
      param :sync_token, :string, as: "syncToken"
      param :page_token, :string, as: "pageToken"
      param :max_results, :integer, as: "maxResults", constraints: [min: 1, max: 2500]
      param :single_events, :boolean, as: "singleEvents"
      param :show_deleted, :boolean, as: "showDeleted"
      param :time_min, :utc_datetime, as: "timeMin"
      param :time_max, :utc_datetime, as: "timeMax"
    end
  end
end

defmodule AshEnterprise.Test.CalendarFixtures do
  @moduledoc """
  SYNTHETIC Google Calendar API v3 payloads for the calendar vertical's tests.

  Shapes follow Google's public reference for `calendarList.list` and
  `events.list` (kind/etag/id/status/summary/start/end/organizer/attendees,
  `nextPageToken`/`nextSyncToken`). Every value is invented: the people are
  on `example.test`, the ids are made up, nothing was copied from a real
  calendar. Each content string carries the marker `SYNTHETIC-CONTENT` so the
  log-leak tests can look for it.
  """

  @marker "SYNTHETIC-CONTENT"

  @primary "synthetic.owner@example.test"
  @team "team-synthetic-0001@group.calendar.google.com"

  def marker, do: @marker
  def primary_calendar, do: @primary
  def team_calendar, do: @team

  @doc "Every content string the fixtures carry, for leak assertions."
  def content_strings do
    [
      "#{@marker} planning block",
      "#{@marker} design review",
      "#{@marker} design review (moved)",
      "#{@marker} offsite",
      "#{@marker} room 4",
      "Ada #{@marker}",
      "ada@example.test",
      "grace@example.test",
      "linus@example.test",
      @primary,
      @team
    ]
  end

  def calendar_list(ids \\ [@primary, @team]) do
    %{
      "kind" => "calendar#calendarList",
      "etag" => "\"synthetic-etag-list\"",
      "nextSyncToken" => "calendar-list-sync-synthetic",
      "items" =>
        Enum.map(ids, fn id ->
          %{
            "kind" => "calendar#calendarListEntry",
            "id" => id,
            "summary" => "#{@marker} calendar",
            "timeZone" => "America/Toronto",
            "accessRole" => if(id == @primary, do: "owner", else: "reader"),
            "primary" => id == @primary
          }
        end)
    }
  end

  @doc "A timed, confirmed event with an organizer, attendees and a room."
  def planning_event do
    %{
      "kind" => "calendar#event",
      "etag" => "\"3300000000000001\"",
      "id" => "synthev0001",
      "status" => "confirmed",
      "summary" => "#{@marker} planning block",
      "location" => "#{@marker} room 4",
      "iCalUID" => "synthev0001@google.com",
      "start" => %{"dateTime" => "2026-10-13T09:00:00-04:00", "timeZone" => "America/Toronto"},
      "end" => %{"dateTime" => "2026-10-13T09:30:00-04:00", "timeZone" => "America/Toronto"},
      "organizer" => %{"email" => "ada@example.test", "displayName" => "Ada #{@marker}"},
      "attendees" => [
        %{"email" => "ada@example.test", "displayName" => "Ada #{@marker}", "organizer" => true},
        %{"email" => @primary, "self" => true, "responseStatus" => "accepted"},
        %{
          "email" => "c_synthetic-room@resource.calendar.google.com",
          "displayName" => "Room 4",
          "resource" => true
        }
      ]
    }
  end

  def review_event(summary \\ "#{@marker} design review") do
    %{
      "kind" => "calendar#event",
      "etag" => "\"3300000000000002\"",
      "id" => "synthev0002",
      "status" => "confirmed",
      "summary" => summary,
      "iCalUID" => "synthev0002@google.com",
      "start" => %{"dateTime" => "2026-10-14T14:00:00Z"},
      "end" => %{"dateTime" => "2026-10-14T15:00:00Z"},
      "organizer" => %{"email" => "grace@example.test"},
      "attendees" => [%{"email" => "grace@example.test"}, %{"email" => "linus@example.test"}]
    }
  end

  @doc "An all-day event: `date`, not `dateTime`, and no organizer name."
  def offsite_event do
    %{
      "kind" => "calendar#event",
      "etag" => "\"3300000000000003\"",
      "id" => "synthev0003",
      "status" => "tentative",
      "summary" => "#{@marker} offsite",
      "iCalUID" => "synthev0003@google.com",
      "start" => %{"date" => "2026-10-16"},
      "end" => %{"date" => "2026-10-17"},
      "organizer" => %{"email" => @primary, "self" => true}
    }
  end

  @doc "How an incremental sync reports a deleted event: id and status only."
  def bare_cancellation(id) do
    %{
      "kind" => "calendar#event",
      "etag" => "\"3300000000000099\"",
      "id" => id,
      "status" => "cancelled"
    }
  end

  def events_page(items, next) do
    base = %{
      "kind" => "calendar#events",
      "etag" => "\"synthetic-etag-events\"",
      "summary" => "#{@marker} calendar",
      "timeZone" => "America/Toronto",
      "accessRole" => "owner",
      "items" => items
    }

    case next do
      {:page, token} -> Map.put(base, "nextPageToken", token)
      {:sync, token} -> Map.put(base, "nextSyncToken", token)
    end
  end

  @doc "Google's 410 for an expired sync token."
  def gone do
    %{
      "error" => %{
        "code" => 410,
        "message" => "Sync token is no longer valid, a full sync is required.",
        "errors" => [
          %{
            "domain" => "global",
            "reason" => "fullSyncRequired",
            "message" => "Sync token is no longer valid, a full sync is required."
          }
        ]
      }
    }
  end
end

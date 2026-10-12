defmodule AshEnterprise.Integration.CalendarSyncTest do
  @moduledoc """
  The Google Calendar vertical end to end: calendar list → events.list with
  sync tokens → `Landing.land/2` under the linked account's scope →
  `Projections.Calendar` → canonical rows, driven through `Sync.run_step` and
  `SyncWorker`.

  No network and no real data: every request is answered by a `Req.Test`
  stub over `AshEnterprise.Test.CalendarFixtures` (synthetic payloads shaped
  from Google's public reference), and the lander is a test lander that lands
  those synthetic records into `SourceObject` so idempotency can be checked
  on the real landing table.
  """

  # Application env, the OS environment and the Logger level are global.
  use AshEnterprise.DataCase, async: false

  use Oban.Testing,
    repo: AshEnterprise.Repo,
    prefix: :ash_enterprise |> Application.get_env(Oban, []) |> Keyword.get(:prefix, "public")

  import ExUnit.CaptureLog

  alias AshEnterprise.Canonical.{CalendarEvent, Person}
  alias AshEnterprise.Canonical.Projections.Calendar, as: Projector
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.Calendar.{Sync, SyncCursor, SyncError, SyncWorker}
  alias AshEnterprise.Integration.{GoogleCalendar, Landing, LinkedAccount, ProxyError}
  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.ActorContext.Grant
  alias AshEnterprise.Test.CalendarFixtures, as: F

  require Ash.Query

  @fake_secret "nango-test-secret-not-a-real-key"
  @nango_env AshEnterprise.Integration.Nango
  @landing_env AshEnterprise.Integration.Landing
  @calendar_env AshEnterprise.Integration.Calendar

  @calendar_list_path "/proxy/calendar/v3/users/me/calendarList"

  # --- test doubles --------------------------------------------------------------

  defmodule SourceObjectLander do
    @moduledoc false
    # Lands the (synthetic) record into the real landing table, so re-landing
    # is checked against the real upsert identity, and tells the test what
    # landed under which scope.
    @behaviour AshEnterprise.Integration.Landing

    @impl true
    def land(record, scope_ref) do
      if pid = Process.get(:calendar_test_pid),
        do: send(pid, {:landed, record.external_id, scope_ref})

      AshEnterprise.Ingestion.SourceObject.land(
        %{
          external_system: record.external_system,
          external_id: record.external_id,
          raw_payload: record.raw_payload,
          source_metadata: Map.put(record.source_metadata, "stream", record.stream),
          cursor: record.cursor,
          fetched_at: record.fetched_at
        },
        authorize?: false
      )
    end
  end

  defmodule GrantedLoader do
    @moduledoc false
    # Loads the job's user and attaches the operator grants built by hand —
    # the privileges of these new resources are not seeded until their domains
    # are registered. The real loader is exercised separately.
    @behaviour AshEnterprise.Integration.Calendar.ActorLoader

    @impl true
    def load(user_id, organization_id) do
      user = Ash.get!(AshEnterprise.Accounts.User, user_id, authorize?: false)

      {:ok,
       ActorContext.attach(user, %ActorContext{
         user_id: user.id,
         organization_id: organization_id,
         principal_ids: [user.id],
         grants: AshEnterprise.Integration.CalendarSyncTest.grants()
       })}
    end
  end

  # The grants a dogfood operator holds: Basic on their own linked accounts,
  # Global read (= may call) on the Calendar operations and on the sync entry
  # points.
  def grants do
    %{
      {inspect(LinkedAccount), :read} => %Grant{basic?: true},
      {inspect(LinkedAccount), :create} => %Grant{basic?: true},
      {inspect(GoogleCalendar), :read} => %Grant{global?: true},
      {inspect(Sync), :read} => %Grant{global?: true}
    }
  end

  # --- setup -----------------------------------------------------------------------

  setup do
    previous = %{
      secret: System.get_env("NANGO_SECRET_KEY"),
      nango: Application.get_env(:ash_enterprise, @nango_env),
      landing: Application.get_env(:ash_enterprise, @landing_env),
      calendar: Application.get_env(:ash_enterprise, @calendar_env)
    }

    System.put_env("NANGO_SECRET_KEY", @fake_secret)

    Application.put_env(:ash_enterprise, @nango_env,
      base_url: "http://nango.test",
      req_options: [plug: {Req.Test, Proxy}],
      sleep: fn _ms -> :ok end,
      max_attempts: 1
    )

    Application.put_env(:ash_enterprise, @landing_env, lander: SourceObjectLander)
    Application.put_env(:ash_enterprise, @calendar_env, actor_loader: GrantedLoader)
    Process.put(:calendar_test_pid, self())

    on_exit(fn ->
      restore_os_env("NANGO_SECRET_KEY", previous.secret)
      restore_app_env(@nango_env, previous.nango)
      restore_app_env(@landing_env, previous.landing)
      restore_app_env(@calendar_env, previous.calendar)
    end)

    org = organization("calendar-sync")
    alice = user(org, "alice")
    bob = user(org, "bob")

    alice_cal = link!(alice, "google-calendar", "conn-cal-alice-synthetic")
    bob_cal = link!(bob, "google-calendar", "conn-cal-bob-synthetic")

    %{org: org, alice: alice, bob: bob, alice_cal: alice_cal, bob_cal: bob_cal}
  end

  # The scenario every "first sync" test starts from: two calendars, the
  # primary paged in two, the team calendar showing the same meeting as the
  # primary (same event id, same iCalUID — as Google does for an invitation).
  defp first_sync_routes do
    %{
      calendar_list: {200, F.calendar_list()},
      events: %{
        {F.primary_calendar(), nil, nil} =>
          {200,
           F.events_page([F.planning_event(), F.review_event()], {:page, "page-2-synthetic"})},
        {F.primary_calendar(), nil, "page-2-synthetic"} =>
          {200, F.events_page([F.offsite_event()], {:sync, "sync-primary-1"})},
        {F.team_calendar(), nil, nil} =>
          {200, F.events_page([F.planning_event()], {:sync, "sync-team-1"})}
      }
    }
  end

  # --- first sync ------------------------------------------------------------------

  describe "first sync" do
    test "lands every event under the account's scope and projects it", ctx do
      stub_google(first_sync_routes())

      assert {:ok, summary} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert summary.status == :complete
      assert summary.calendars == 2
      assert summary.pages == 3
      assert summary.landed == 4
      assert summary.resets == 0
      assert summary.projection.projected == 4

      scope = Landing.scope(ctx.alice_cal)
      landed = collect_landed()
      assert length(landed) == 4
      assert Enum.all?(landed, fn {_id, landed_scope} -> landed_scope == scope end)

      # The shared meeting landed once per calendar: distinct external ids.
      assert landed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 4

      assert [first_page, second_page, team_page] = events_requests()
      assert first_page.query["showDeleted"] == "true"
      assert first_page.query["singleEvents"] == "false"
      refute Map.has_key?(first_page.query, "syncToken")
      assert second_page.query["pageToken"] == "page-2-synthetic"
      assert team_page.calendar == F.team_calendar()

      assert source_object_count() == 4
      assert length(events(ctx.org)) == 4
    end

    test "stores a cursor per calendar: the sync token, no page token", ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      cursors = cursors(ctx)

      assert cursors |> Enum.map(& &1.calendar_id) |> Enum.sort() ==
               Enum.sort([F.primary_calendar(), F.team_calendar()])

      for cursor <- cursors do
        assert cursor.listed
        assert cursor.page_token == nil
        assert cursor.last_synced_at
        assert cursor.owner_id == ctx.alice.id
      end

      assert Enum.find(cursors, &(&1.calendar_id == F.primary_calendar())).sync_token ==
               "sync-primary-1"

      assert Enum.find(cursors, &(&1.calendar_id == F.team_calendar())).sync_token ==
               "sync-team-1"
    end

    test "projects times to UTC, all-day at midnight, people by email (rooms are not people)",
         ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      primary = cursor_for(ctx, F.primary_calendar())

      planning = event!(ctx.org, Projector.external_id(primary.id, "synthev0001"))
      assert planning.title == "#{F.marker()} planning block"
      assert planning.starts_at == ~U[2026-10-13 13:00:00.000000Z]
      assert planning.ends_at == ~U[2026-10-13 13:30:00.000000Z]
      assert planning.location == "#{F.marker()} room 4"
      assert planning.external_system == "google_calendar"

      organizer = Ash.get!(Person, planning.organizer_id, tenant: ctx.org.id, authorize?: false)
      assert to_string(organizer.email) == "ada@example.test"
      assert organizer.name == "Ada #{F.marker()}"
      assert organizer.owner_id == ctx.alice.id

      offsite = event!(ctx.org, Projector.external_id(primary.id, "synthev0003"))
      assert offsite.starts_at == ~U[2026-10-16 00:00:00.000000Z]
      assert offsite.ends_at == ~U[2026-10-17 00:00:00.000000Z]

      emails = ctx.org |> people() |> Enum.map(&to_string(&1.email)) |> Enum.sort()

      assert emails ==
               Enum.sort([
                 "ada@example.test",
                 "grace@example.test",
                 "linus@example.test",
                 F.primary_calendar()
               ])
    end

    test "the page budget stops mid-pass and the next step resumes from the page token", ctx do
      stub_google(first_sync_routes())
      put_calendar_env(max_pages: 1)

      assert {:ok, %{status: :more, pages: 1, landed: 2}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      primary = cursor_for(ctx, F.primary_calendar())
      assert primary.page_token == "page-2-synthetic"
      assert primary.sync_token == nil

      assert {:ok, %{status: :more, pages: 1}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert cursor_for(ctx, F.primary_calendar()).sync_token == "sync-primary-1"
      assert cursor_for(ctx, F.team_calendar()).sync_token == nil

      put_calendar_env(max_pages: 20)

      stub_google(
        put_in(
          first_sync_routes(),
          [:events, {F.primary_calendar(), "sync-primary-1", nil}],
          {200, F.events_page([], {:sync, "sync-primary-2"})}
        )
      )

      assert {:ok, %{status: :complete, pages: 2}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert cursor_for(ctx, F.team_calendar()).sync_token == "sync-team-1"
      assert source_object_count() == 4
    end
  end

  # --- incremental sync --------------------------------------------------------------

  describe "incremental sync" do
    setup ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)
      _ = collect_landed()
      _ = events_requests()
      :ok
    end

    test "sends the stored sync token and applies only what changed", ctx do
      stub_google(%{
        calendar_list: {200, F.calendar_list()},
        events: %{
          {F.primary_calendar(), "sync-primary-1", nil} =>
            {200,
             F.events_page(
               [F.review_event("#{F.marker()} design review (moved)")],
               {:sync, "sync-primary-2"}
             )},
          {F.team_calendar(), "sync-team-1", nil} =>
            {200, F.events_page([], {:sync, "sync-team-2"})}
        }
      })

      assert {:ok, summary} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert summary.status == :complete
      assert summary.landed == 1
      assert summary.projection.projected == 1

      assert [primary_request, team_request] = events_requests()
      assert primary_request.query["syncToken"] == "sync-primary-1"
      assert team_request.query["syncToken"] == "sync-team-1"

      primary = cursor_for(ctx, F.primary_calendar())
      assert primary.sync_token == "sync-primary-2"

      review = event!(ctx.org, Projector.external_id(primary.id, "synthev0002"))
      assert review.title == "#{F.marker()} design review (moved)"
      assert length(events(ctx.org)) == 4
      assert source_object_count() == 4
    end

    test "a cancelled event is kept and marked cancelled, not deleted", ctx do
      stub_google(%{
        calendar_list: {200, F.calendar_list()},
        events: %{
          {F.primary_calendar(), "sync-primary-1", nil} =>
            {200, F.events_page([F.bare_cancellation("synthev0002")], {:sync, "sync-primary-2"})},
          {F.team_calendar(), "sync-team-1", nil} =>
            {200, F.events_page([], {:sync, "sync-team-2"})}
        }
      })

      assert {:ok, summary} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      primary = cursor_for(ctx, F.primary_calendar())
      review = event!(ctx.org, Projector.external_id(primary.id, "synthev0002"))

      # The row survives with its title and times.
      assert review.title == "#{F.marker()} design review"
      assert review.starts_at == ~U[2026-10-14 14:00:00.000000Z]
      assert length(events(ctx.org)) == 4

      if Projector.status_supported?() do
        assert summary.projection.cancelled == 1
        assert Map.get(review, :status) == :cancelled
      else
        # CalendarEvent has no status attribute yet: the gap is reported, not hidden.
        assert summary.projection.cancelled_unrecorded == 1
      end
    end

    test "a calendar that leaves the list is un-listed, not deleted, and not synced", ctx do
      stub_google(%{
        calendar_list: {200, F.calendar_list([F.primary_calendar()])},
        events: %{
          {F.primary_calendar(), "sync-primary-1", nil} =>
            {200, F.events_page([], {:sync, "sync-primary-2"})}
        }
      })

      assert {:ok, %{calendars: 1}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      team = cursor_for(ctx, F.team_calendar())
      refute team.listed
      assert team.sync_token == "sync-team-1"
      assert [%{calendar: calendar}] = events_requests()
      assert calendar == F.primary_calendar()
    end
  end

  # --- cursor reset ------------------------------------------------------------------

  describe "cursor reset" do
    setup ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)
      _ = collect_landed()
      _ = events_requests()
      :ok
    end

    test "410 Gone resets the cursor explicitly and full-syncs that calendar", ctx do
      stub_google(%{
        calendar_list: {200, F.calendar_list()},
        events: %{
          {F.primary_calendar(), "sync-primary-1", nil} => {410, F.gone()},
          {F.primary_calendar(), nil, nil} =>
            {200,
             F.events_page(
               [F.planning_event(), F.review_event(), F.offsite_event()],
               {:sync, "sync-primary-fresh"}
             )},
          {F.team_calendar(), "sync-team-1", nil} =>
            {200, F.events_page([], {:sync, "sync-team-2"})}
        }
      })

      assert {:ok, summary} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert summary.status == :complete
      assert summary.resets == 1
      assert summary.landed == 3

      assert [stale, full, _team] = events_requests()
      assert stale.query["syncToken"] == "sync-primary-1"
      refute Map.has_key?(full.query, "syncToken")

      primary = cursor_for(ctx, F.primary_calendar())
      assert primary.sync_token == "sync-primary-fresh"
      assert primary.reset_count == 1
      assert primary.last_reset_at

      # The full resync re-landed the same events in place.
      assert source_object_count() == 4
      assert length(events(ctx.org)) == 4
    end

    test "410 again straight after the reset stops the step instead of looping", ctx do
      stub_google(%{
        calendar_list: {200, F.calendar_list()},
        events: %{
          {F.primary_calendar(), "sync-primary-1", nil} => {410, F.gone()},
          {F.primary_calendar(), nil, nil} => {410, F.gone()}
        }
      })

      assert {:error, error} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert %SyncError{reason: :repeated_gone} = SyncError.unwrap(error)
      assert length(events_requests()) == 2
    end

    test "reset_sync is the explicit operator reset: every cursor forgets its tokens", ctx do
      assert {:ok, %{reset: 2}} =
               Sync.reset_sync(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      for cursor <- cursors(ctx) do
        assert cursor.sync_token == nil
        assert cursor.page_token == nil
        assert cursor.reset_count == 1
      end

      refute_received {:request, _}
    end
  end

  # --- idempotency -------------------------------------------------------------------

  describe "idempotent re-runs" do
    test "a full resync of the same events duplicates nothing", ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      before = snapshot(ctx.org)

      {:ok, _} = Sync.reset_sync(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      {:ok, %{landed: 4}} =
        Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert snapshot(ctx.org) == before
      assert source_object_count() == 4
      assert length(cursors(ctx)) == 2
    end

    test "re-running a caught-up step lands nothing", ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)
      _ = collect_landed()

      stub_google(%{
        calendar_list: {200, F.calendar_list()},
        events: %{
          {F.primary_calendar(), "sync-primary-1", nil} =>
            {200, F.events_page([], {:sync, "sync-primary-1"})},
          {F.team_calendar(), "sync-team-1", nil} =>
            {200, F.events_page([], {:sync, "sync-team-1"})}
        }
      })

      assert {:ok, %{landed: 0}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert {:ok, %{landed: 0}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert collect_landed() == []
    end

    test "re-projecting the landed rows (replay) converges on the same canonical rows", ctx do
      stub_google(first_sync_routes())
      {:ok, _} = Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)
      before = snapshot(ctx.org)

      sources =
        SourceObject
        |> Ash.Query.filter(external_system == "google_calendar")
        |> Ash.Query.sort(:external_id)
        |> Ash.read!(authorize?: false)

      assert {:ok, %{projected: 4}} =
               Projector.replay(sources, %{owner_id: ctx.alice.id, tenant_id: ctx.org.id})

      assert snapshot(ctx.org) == before
    end
  end

  # --- the worker --------------------------------------------------------------------

  describe "SyncWorker" do
    test "request_sync enqueues one ids-only job per account; a second request collapses", ctx do
      assert {:ok, %{already_enqueued: false, linked_account_id: id}} =
               Sync.request_sync(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert id == ctx.alice_cal.id

      assert {:ok, %{already_enqueued: true}} = Sync.request_sync(%{}, actor: ctx.alice)

      assert [job] = all_enqueued(worker: SyncWorker)

      assert job.args == %{
               "user_id" => ctx.alice.id,
               "linked_account_id" => ctx.alice_cal.id,
               "organization_id" => ctx.org.id
             }

      assert job.queue == "ingestion"
    end

    test "perform runs one step as the account's owner", ctx do
      stub_google(first_sync_routes())

      assert {:ok, %{status: :complete, landed: 4}} =
               perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))

      assert_received {:request, %{connection_id: ["conn-cal-alice-synthetic"]}}
      refute_received {:request, %{connection_id: ["conn-cal-bob-synthetic"]}}
    end

    test "an unfinished pass snoozes the job so the next step continues it", ctx do
      stub_google(first_sync_routes())
      put_calendar_env(actor_loader: GrantedLoader, max_pages: 1)

      assert {:snooze, 1} = perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))
    end

    test "args naming another user's account resolve nothing and send nothing", ctx do
      tripwire_stub()

      args = %{SyncWorker.args(ctx.bob_cal) | "user_id" => ctx.alice.id}

      assert {:cancel, :no_linked_account} = perform_job(SyncWorker, args)
      refute_received :http_called

      assert {:error, error} =
               Sync.request_sync(%{linked_account_id: ctx.bob_cal.id}, actor: ctx.alice)

      assert ProxyError.reason(error) == :no_linked_account
    end

    test "rate limiting snoozes for the provider's Retry-After", ctx do
      test_pid = self()

      Req.Test.stub(Proxy, fn conn ->
        send(test_pid, :http_called)

        conn
        |> Plug.Conn.put_resp_header("retry-after", "120")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "error" => %{"code" => 429, "errors" => [%{"reason" => "rateLimitExceeded"}]}
        })
      end)

      assert {:snooze, 120} = perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))
    end

    test "revoked credentials cancel instead of retrying", ctx do
      Req.Test.stub(Proxy, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => 401, "errors" => [%{"reason" => "authError"}]}})
      end)

      assert {:cancel, :unauthorized} = perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))
    end

    test "with the real actor loader and no granted role, the policy refuses before any request",
         ctx do
      tripwire_stub()
      put_calendar_env([])

      assert {:cancel, :forbidden_by_policy} =
               perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))

      refute_received :http_called
    end
  end

  # --- landing and authorization ----------------------------------------------------

  describe "nothing lands without scoped landing" do
    test "the default lander refuses: nothing persisted, no cursor advanced, the job cancels",
         ctx do
      Application.delete_env(:ash_enterprise, @landing_env)
      stub_google(first_sync_routes())

      assert {:error, error} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: ctx.alice)

      assert %SyncError{reason: :landing_refused, detail: :scoped_landing_not_wired} =
               SyncError.unwrap(error)

      assert source_object_count() == 0
      assert events(ctx.org) == []
      assert people(ctx.org) == []

      for cursor <- cursors(ctx) do
        assert cursor.sync_token == nil
        assert cursor.page_token == nil
      end

      assert {:cancel, "landing_refused: scoped_landing_not_wired"} =
               perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))
    end
  end

  describe "authorization" do
    test "without the Sync grant the step is forbidden and nothing is sent", ctx do
      tripwire_stub()
      actor = actor(ctx.alice, ctx.org, Map.delete(grants(), {inspect(Sync), :read}))

      assert {:error, %Ash.Error.Forbidden{}} =
               Sync.run_step(%{linked_account_id: ctx.alice_cal.id}, actor: actor)

      refute_received :http_called
    end

    test "a system actor owns no linked account and syncs nothing", _ctx do
      tripwire_stub()

      assert {:error, error} =
               Sync.run_step(%{}, actor: AshEnterprise.Platform.SystemActor.seed())

      assert ProxyError.reason(error) == :no_linked_account
      refute_received :http_called
    end
  end

  # --- content never reaches the log -----------------------------------------------

  describe "logging" do
    test "a full sync, a reset and a failure log no event content, tokens or calendar ids", ctx do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :info], fn ->
          stub_google(first_sync_routes())
          {:ok, _} = perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))

          stub_google(%{
            calendar_list: {200, F.calendar_list()},
            events: %{
              {F.primary_calendar(), "sync-primary-1", nil} => {410, F.gone()},
              {F.primary_calendar(), nil, nil} => {410, F.gone()}
            }
          })

          {:error, _} = perform_job(SyncWorker, SyncWorker.args(ctx.alice_cal))
        end)

      for secret <-
            F.content_strings() ++
              [
                F.marker(),
                "sync-primary-1",
                "page-2-synthetic",
                "conn-cal-alice-synthetic",
                @fake_secret
              ] do
        refute log =~ secret, "log output contains #{inspect(secret)}"
      end
    end
  end

  # --- helpers -------------------------------------------------------------------

  # Answers calendarList and events.list from a route table keyed on
  # {calendar_id, syncToken, pageToken}; anything unrouted is a 404 so a test
  # that forgets a route fails loudly.
  defp stub_google(routes) do
    test_pid = self()

    Req.Test.stub(Proxy, fn conn ->
      query = URI.decode_query(conn.query_string)

      summary = %{
        path: conn.request_path,
        query: query,
        connection_id: Plug.Conn.get_req_header(conn, "connection-id"),
        calendar: calendar_of(conn.request_path)
      }

      send(test_pid, {:request, summary})

      {status, body} =
        case summary do
          %{path: @calendar_list_path} ->
            routes.calendar_list

          %{calendar: calendar} when is_binary(calendar) ->
            Map.get(
              routes.events,
              {calendar, query["syncToken"], query["pageToken"]},
              {404, %{"error" => %{"code" => 404, "errors" => [%{"reason" => "notFound"}]}}}
            )
        end

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp calendar_of(path) do
    case Regex.run(~r{^/proxy/calendar/v3/calendars/([^/]+)/events$}, path) do
      [_, encoded] -> URI.decode(encoded)
      _ -> nil
    end
  end

  defp tripwire_stub do
    test_pid = self()

    Req.Test.stub(Proxy, fn conn ->
      send(test_pid, :http_called)
      Req.Test.json(conn, %{})
    end)
  end

  # Drains the recorded events.list requests in arrival order (calendarList
  # requests are dropped). Other messages stay in the mailbox.
  defp events_requests(acc \\ []) do
    receive do
      {:request, %{calendar: calendar} = request} when is_binary(calendar) ->
        events_requests([request | acc])

      {:request, _calendar_list} ->
        events_requests(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_landed(acc \\ []) do
    receive do
      {:landed, id, scope} -> collect_landed([{id, scope} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp cursors(ctx) do
    SyncCursor.for_account!(ctx.alice_cal.id, tenant: ctx.org.id, authorize?: false)
  end

  defp cursor_for(ctx, calendar_id) do
    Enum.find(cursors(ctx), &(&1.calendar_id == calendar_id))
  end

  defp event!(org, external_id) do
    CalendarEvent.by_external!("google_calendar", external_id, tenant: org.id, authorize?: false)
  end

  defp events(org) do
    CalendarEvent
    |> Ash.Query.filter(external_system == "google_calendar")
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(tenant: org.id, authorize?: false)
  end

  defp people(org) do
    Person
    |> Ash.Query.sort(:email)
    |> Ash.read!(tenant: org.id, authorize?: false)
  end

  defp snapshot(org) do
    events =
      for e <- events(org) do
        {e.id, e.external_id, e.title, e.starts_at, e.ends_at, e.location, e.organizer_id}
      end

    people = for p <- people(org), do: {p.id, to_string(p.email), p.name}
    {events, people}
  end

  defp source_object_count do
    SourceObject
    |> Ash.Query.filter(external_system == "google_calendar")
    |> Ash.count!(authorize?: false)
  end

  defp put_calendar_env(opts) do
    Application.put_env(:ash_enterprise, @calendar_env, opts)
  end

  defp actor(user, org, grants \\ grants()) do
    ActorContext.attach(user, %ActorContext{
      user_id: user.id,
      organization_id: org.id,
      principal_ids: [user.id],
      grants: grants
    })
  end

  defp organization(name) do
    unique = "#{name}-#{System.unique_integer([:positive])}"

    AshEnterprise.Accounts.Organization
    |> Ash.Changeset.for_create(:create, %{name: unique, unique_name: unique}, authorize?: false)
    |> Ash.create!()
  end

  defp user(org, name) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "#{name}-#{System.unique_integer([:positive])}@calendar-sync.test",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> actor(org)
  end

  defp link!(actor, provider_config_key, connection_id) do
    LinkedAccount.link!(
      %{provider_config_key: provider_config_key, connection_id: connection_id},
      actor: actor,
      tenant: ActorContext.tenant(actor)
    )
  end

  defp restore_os_env(name, nil), do: System.delete_env(name)
  defp restore_os_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:ash_enterprise, key)
  defp restore_app_env(key, value), do: Application.put_env(:ash_enterprise, key, value)
end

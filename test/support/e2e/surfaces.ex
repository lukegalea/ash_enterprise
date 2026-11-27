defmodule AshEnterpriseWeb.E2E.Surfaces do
  @moduledoc """
  The surfaces this application's browser tier drives, for
  `AshBrowserTests.Surfaces`.

  ## What this declares, and what it does not

  `AshEnterprise.Surfaces.all/0` holds every surface of the application. This
  host declares **the subset adopted so far**, not all of them, and that
  distinction is the whole reason to read this moduledoc.

  The ledger's contract is "nothing *declared* is silently skipped": it fails if
  a declared surface is neither exercised nor waived. It cannot fail for a
  registry surface this module never mentions. So the number below is a measure
  of how far adoption has got, and growing it is the work — not a thing that
  happens by itself.

  Deliberately not solved by returning the whole registry with a generated
  waiver per surface: a waiver is meant to be a decision someone made with a
  reason, and fifty generated ones would say nothing while making the ledger
  look complete. A new surface would also be auto-waived, which is precisely
  the silence the ledger exists to break.

  ## Documented by a journey

  The same surfaces and row actions have a second account
  (`AshBrowserTests.Journeys.assert_documented!/3`, run by
  `AshEnterprise.JourneyLedgerTest`): each is walked by a journey whose approved
  run the lock still holds current, or carries an `:undocumented` waiver below
  that says why not. The waivers are written here by hand, one reason each; the
  ledger refuses a reason shared by two of them, so they cannot be stamped out
  from the registry. How much of the whole registry the journeys walk is
  reported by that test, and waivers do not count toward it.

  ## The actor

  One seeded tenant admin (`AshEnterprise.Test.DailyFixtures.tenant!/1`), signed in
  through the session cookie rather than the form —
  `AshEnterpriseWeb.E2E.Login`. Surfaces whose door is closed to a plain admin
  need their own actor and are not in the adopted set yet. A row-action test signs
  in as the admin `row_for/3` seeded its row for, since the row must be in that
  admin's organization.

  ## Row actions and their audit rows

  The A2UI row actions of `@row_actions_adopted` are generated tests too, and the
  ledger holds them. Each asserts the chain from the server's `handle_event` to the
  Ash action (there is no browser span to root it at), then `assert_audit/2`: an
  `audit_events` row for the record the action changed, with the action's name,
  carrying that `handle_event` span's correlation id. The span shows the request
  arrived; only the audit row shows the action wrote.
  """

  @behaviour AshBrowserTests.Surfaces.Host
  @behaviour AshBrowserTests.A2uiManifest

  import ExUnit.Assertions

  require Ash.Query

  alias AshA2ui.Manifest
  alias AshBrowserTests.Surface
  alias AshBrowserTests.Trace
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterpriseWeb.E2E.Login

  # The adopted set, by registry key: the day surfaces a seeded tenant admin can
  # open with no further fixtures, because `DailyFixtures` already furnishes
  # them.
  #
  # `/app` (the launcher) is deliberately absent: it is a plain route, not a
  # registry surface, so there is no key to name it by.
  @adopted [:today, :calendar, :inbox, :users]

  # The adopted surfaces whose row actions are adopted too. Today's and the inbox's
  # approvals are not yet: adopting them needs a seeded approval per action, so their
  # row actions are left out of the manifest rather than generated and failing.
  @row_actions_adopted %{"users" => AshEnterpriseWeb.A2ui.UserUI}

  # The generator's default surface chain is `[browser_connect(), live_mount()]`
  # — rooted at a span the *browser* emits. This application has no browser
  # tracing: no `otel-browser` meta tag, no tracer in `app.js`, no span ingest
  # route. That chain can therefore never match here, and every generated test
  # would fail on an absent span rather than on anything being wrong.
  #
  # What this host can assert is the server half: the LiveView mounted, and the
  # SQL underneath belongs to that mount's trace. Browser-rooted chains become
  # possible if this application adopts browser tracing, and `chain:` is the
  # seam for it.
  #
  # Two spans rather than one because `assert_chain/3` asserts *links* — it
  # takes two matchers at minimum, and one span is not a chain. Asserting the
  # link is the point: a mount span and a query span can both exist while
  # belonging to different traces, which is the failure a surface test is for.
  @server_chain [AshBrowserTests.Trace.live_mount(), AshBrowserTests.Trace.query()]

  @impl true
  def surfaces do
    registry = AshEnterprise.Surfaces.all()

    # An adopted key that names nothing is a typo or a renamed surface, and
    # without this it is *silent*: the filter below simply yields one surface
    # fewer, the ledger has nothing to miss, and coverage shrinks with every
    # test still green. `:launcher` was exactly that until it was caught by
    # counting the generated tests by hand.
    case Enum.reject(@adopted, fn key -> Enum.any?(registry, &(&1.key == key)) end) do
      [] ->
        :ok

      unknown ->
        raise "adopted surfaces not in AshEnterprise.Surfaces: #{inspect(unknown)}"
    end

    registry
    |> Enum.filter(&(&1.key in @adopted and is_binary(&1.path)))
    |> Enum.map(
      &%Surface{id: to_string(&1.key), path: &1.path, actor: :admin, chain: @server_chain}
    )
  end

  # Each is a decision about one surface or row action, with its reason: why no
  # journey walks it yet. Delete a waiver when a journey that walks its target is
  # approved; the ledger fails until then.
  @impl true
  def waivers do
    [
      {:undocumented, :surface, "today",
       "Today is the person's morning brief and agenda, both built from their " <>
         "calendar events. The journey world seeds an organization and its people " <>
         "but no events, so a journey here could only show an empty day."},
      {:undocumented, :surface, "calendar",
       "The calendar shows events projected from a calendar feed (the fixture tap " <>
         "in development, a linked calendar account in ADR 0011). The journey world " <>
         "runs no tap and seeds no events, so every figure of the grid would be empty."},
      {:undocumented, :surface, "inbox",
       "The inbox lists threads synced from a Gmail account linked through Nango. " <>
         "Linking one goes through Google's consent screen, outside the app, and the " <>
         "journey world links no account and seeds no threads."},
      {:undocumented, :action, {"users", "row:table.activate"},
       "Activating brings back someone who was deactivated, such as a returning " <>
         "contractor. The offboarding journey ends once access is revoked; bringing " <>
         "a person back is a goal of its own, and no journey is written for it yet."}
    ]
  end

  # The host seeds its own actor rather than taking one from the ExUnit context:
  # the tier runs inside the SQL sandbox, so a tenant seeded in one test's
  # connection is invisible to another's and there is nothing to share.
  @impl true
  def sign_in(conn, :admin, context) do
    Login.as(conn, get_in(context, [:row, :admin]) || DailyFixtures.tenant!())
  end

  @impl AshBrowserTests.Surfaces.Host
  def a2ui_manifest, do: __MODULE__

  # The labels are the ones an English reader sees, which is the locale the
  # admin signs in with.
  @impl AshBrowserTests.A2uiManifest
  def manifest(surface_id) do
    case Map.fetch(@row_actions_adopted, surface_id) do
      {:ok, ui} -> Manifest.for_surface(ui, AshEnterpriseWeb.Locale.a2ui_opts("en"))
      :error -> nil
    end
  end

  # A member of a fresh admin's organization, in the state the action applies to
  # (`visible_when`): active to be deactivated, inactive to be activated.
  @impl true
  def row_for(%Surface{id: "users"}, %{ash_action: action}, _context) do
    admin = DailyFixtures.tenant!()
    %{user: user} = DailyFixtures.member!(admin, "Row #{System.unique_integer([:positive])}", [])

    user =
      if action == :activate,
        do:
          user |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false) |> Ash.update!(),
        else: user

    %{text: to_string(user.email), id: user.id, action: action, admin: admin}
  end

  @impl true
  def row_action_chain(%{ash_action: action}),
    do: [Trace.handle_event(), Trace.ash_action(action: action)]

  @impl true
  def assert_audit(correlation_id, %{row: %{id: record_id, action: action}}) do
    assert is_binary(correlation_id), "the handle_event span carries no ash.correlation_id"

    events =
      EventLog
      |> Ash.Query.filter(correlation_id == ^correlation_id and record_id == ^record_id)
      |> Ash.read!(authorize?: false)

    assert Enum.any?(events, &(&1.resource == User and &1.action == action)),
           "no audit row for #{action} on #{record_id} with correlation id #{correlation_id}; " <>
             "rows with that correlation and record: #{inspect(Enum.map(events, & &1.action))}"
  end
end

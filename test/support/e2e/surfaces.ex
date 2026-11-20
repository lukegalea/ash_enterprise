defmodule AshEnterpriseWeb.E2E.Surfaces do
  @moduledoc """
  The surfaces this application's browser tier drives, for
  `AshBrowserTests.Surfaces`.

  ## What this declares, and what it does not

  `AshEnterprise.Surfaces.all/0` holds 69 surfaces, 53 of them with a path. This
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

  ## The actor

  One seeded tenant admin (`AshEnterprise.Test.DailyFixtures.tenant!/1`), signed in
  through the session cookie rather than the form —
  `AshEnterpriseWeb.E2E.Login`. Surfaces whose door is closed to a plain admin
  need their own actor and are not in the adopted set yet.
  """

  @behaviour AshBrowserTests.Surfaces.Host

  alias AshBrowserTests.Surface
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterpriseWeb.E2E.Login

  # The adopted set, by registry key: the day surfaces a seeded tenant admin can
  # open with no further fixtures, because `DailyFixtures` already furnishes
  # them.
  #
  # `/app` (the launcher) is deliberately absent: it is a plain route, not a
  # registry surface, so there is no key to name it by.
  @adopted [:today, :calendar, :inbox]

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

  @impl true
  def waivers, do: []

  # The host seeds its own actor rather than taking one from the ExUnit context:
  # the tier runs inside the SQL sandbox, so a tenant seeded in one test's
  # connection is invisible to another's and there is nothing to share.
  @impl true
  def sign_in(conn, :admin, _context), do: Login.as(conn, DailyFixtures.tenant!())
end

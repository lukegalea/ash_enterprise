defmodule AshBrowserTests.JourneysTest do
  @moduledoc false
  # The generated suite: one test per journey and locale the fixture declares.
  use AshBrowserTests.Journeys,
    host: AshBrowserTests.Fixture.JourneyHost,
    journeys: [AshBrowserTests.Fixture.Journeys],
    async: true
end

defmodule AshBrowserTests.JourneysRunTest do
  @moduledoc false
  # The runner itself, in a real browser: what a run writes, and how a journey
  # fails. These run the fixture's journeys by hand, beside the generated suite
  # above, so a journey runs twice at once in one VM and its two runs must land
  # in two directories.
  use AshBrowserTests.Case, async: true

  require Ash.Query

  alias AshBrowserTests.Figure
  alias AshBrowserTests.Fixture.JourneyHost
  alias AshBrowserTests.Fixture.Journeys, as: Passing
  alias AshBrowserTests.Fixture.MoreJourneys
  alias AshBrowserTests.Fixture.Widget
  alias AshBrowserTests.Journeys
  alias AshBrowserTests.Journeys.Candidates
  alias AshBrowserTests.Trace
  alias AshJourneys.Approval
  alias AshJourneys.Lock
  alias AshJourneys.Manifest
  alias AshJourneys.Raster
  alias AshJourneys.Run

  @moduletag screenshot: false
  @moduletag timeout: 180_000

  defp dir(%Manifest{} = manifest),
    do: Run.candidate_dir(File.cwd!(), manifest.run_id, manifest.journey, manifest.locale)

  defp approval_problems(manifest, modules) do
    {:ok, declared} = Lock.declared(modules)
    {:ok, lock} = Lock.read(Path.join(File.cwd!(), "tmp/no-lock"))

    candidate = %{
      journey: manifest.journey,
      locale: manifest.locale,
      dir: dir(manifest),
      manifest: manifest
    }

    Approval.check(candidate, declared, lock)
  end

  # The manifest a run that raised left behind.
  defp written(journey) do
    path =
      File.cwd!()
      |> Run.candidate_dir(Candidates.run_id(), Atom.to_string(journey), "en")
      |> Path.join(Manifest.file_name())

    {:ok, manifest} = Manifest.read(path)
    manifest
  end

  defp widget(name) do
    Widget |> Ash.Query.filter(name == ^name) |> Ash.read_one!(authorize?: false)
  end

  describe "a passing journey" do
    @tag browser_context_opts: Journeys.framing("en")
    test "two personas, two steps: an approvable manifest, one window per step", context do
      manifest = Journeys.run!(JourneyHost, {Passing, :activate_a_widget, "en"}, context)

      assert %Manifest{status: :passed, retries: 0, environment: :test, locale: "en"} = manifest
      assert manifest.browser.name == "chromium" and manifest.browser.version != ""
      assert [viewer, admin] = manifest.steps
      assert {viewer.actor, admin.actor} == {"viewer", "admin"}
      assert Enum.all?(manifest.steps, &(&1.status == :passed and &1.attempts == 1))

      # Each step's window ends where the next one's starts, and holds its spans.
      assert viewer.cursor.from <= viewer.cursor.to
      assert viewer.cursor.to == admin.cursor.from
      assert admin.cursor.from < admin.cursor.to
      assert viewer.span_ids != [] and admin.span_ids != []

      # The step that asked for audit rows asked for them by its correlation id.
      assert is_binary(admin.correlation_id)
      assert_received {:audit_asserted, id}
      assert id == admin.correlation_id

      assert [%{name: "widgets"}] = viewer.figures
      assert [figure] = admin.figures
      assert figure.file == "activate.activated.png"
      assert figure.settled
      assert %{x: _, y: _, width: width, height: height} = figure.highlight
      assert width > 0 and height > 0

      bytes = File.read!(Path.join(dir(manifest), figure.file))
      {:ok, raster} = Raster.decode(bytes)
      assert Raster.hash(raster) == figure.raster_sha256
      assert {raster.width, raster.height} == {figure.width, figure.height}

      assert widget("Sprocket").active
      assert approval_problems(manifest, [Passing]) == []
    end

    @tag browser_context_opts: Journeys.framing("en")
    test "a confirmation left open is captured, then confirmed", context do
      manifest = Journeys.run!(JourneyHost, {Passing, :remove_a_widget, "en"}, context)

      assert [%{status: :passed, figures: [confirm, removed]}] = manifest.steps
      assert {confirm.file, removed.file} == {"remove.confirm.png", "remove.removed.png"}
      assert confirm.width < removed.width
      assert widget("Gizmo") == nil
    end
  end

  describe "a journey that fails" do
    @tag browser_context_opts: Journeys.framing("en")
    test "stops at the failing step, names it, and records it", context do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Journeys.run!(JourneyHost, {MoreJourneys, :stops_at_a_failing_step, "en"}, context)
        end

      assert error.message =~
               "journey stops_at_a_failing_step (en), step 01-expects_too_soon (as viewer): " <>
                 "expect record widget: active is false"

      manifest = written(:stops_at_a_failing_step)
      assert manifest.status == :failed
      assert [failed, skipped] = manifest.steps
      assert {failed.status, skipped.status} == {:failed, :skipped}
      assert failed.error =~ "active is false"
      # The step after it never ran: the widget was never activated.
      refute widget("Sprocket").active
    end

    # S2: the second step's action is real but leaves no span. Its expectation
    # must fail in that step: over the whole test, the first step's spans would
    # satisfy it.
    @tag browser_context_opts: Journeys.framing("en")
    test "a span lost in one step fails that step, not the next", %{test_key: key} = context do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Journeys.run!(JourneyHost, {MoreJourneys, :loses_a_span, "en"}, context)
        end

      assert error.message =~ "step 02-activate_the_second (as admin)"

      manifest = written(:loses_a_span)
      assert Enum.map(manifest.steps, & &1.status) == [:passed, :failed, :skipped]
      assert widget("Untraced sprocket").active

      # What the cursor is for: the same expectation over the test's key passes.
      Trace.assert_chain(key, [Trace.handle_event(), Trace.ash_action(action: :activate)])
    end

    test "a page that does not settle is not captured", %{conn: conn} do
      path = Path.join(["tmp", "settle", "#{System.unique_integer([:positive])}.png"])
      conn = PhoenixTest.visit(conn, "/busy")

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Figure.capture(conn, path, settle: [timeout: 1_000])
        end

      assert error.message =~ "did not settle within 1000ms"
      assert error.message =~ ~s("busy" => 1)
      refute File.exists?(path)
    end
  end

  describe "a retried run" do
    @tag browser_context_opts: Journeys.framing("en")
    test "counts the retry and the step's attempts, and is not approvable", context do
      first = Journeys.run!(JourneyHost, {MoreJourneys, :passes_on_a_retry, "en"}, context)
      assert first.retries == 0

      # The same run id, claimed by another VM: a re-run of the same run.
      File.write!(Path.join(dir(first), ".claim"), "another-vm")

      retried = Journeys.run!(JourneyHost, {MoreJourneys, :passes_on_a_retry, "en"}, context)

      assert retried.run_id == first.run_id
      assert retried.status == :passed
      assert retried.retries == 1
      assert [%{attempts: 2}] = retried.steps

      assert Enum.any?(approval_problems(retried, [MoreJourneys]), &(&1 =~ "retr"))
    end
  end
end

defmodule AshBrowserTests.Journeys.CandidatesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AshBrowserTests.Journeys.Candidates

  @tag :tmp_dir
  test "concurrent runs of one journey never share a directory", %{tmp_dir: root} do
    claims =
      1..8
      |> Task.async_stream(fn _n -> Candidates.claim!(root, "run", "a_journey", "en") end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, claim} -> claim end)

    assert claims |> Enum.map(& &1.dir) |> Enum.uniq() |> length() == 8

    assert claims |> Enum.map(& &1.run_id) |> Enum.sort() ==
             Enum.sort(["run" | Enum.map(2..8, &"run-#{&1}")])

    assert Enum.all?(claims, &(&1.prior == nil))
  end

  @tag :tmp_dir
  test "a claim left by another process is taken over as a retry", %{tmp_dir: root} do
    %{dir: dir} = Candidates.claim!(root, "run", "a_journey", "en")
    File.write!(Path.join(dir, ".claim"), "another-vm")
    File.write!(Path.join(dir, "step.figure.png"), "old")

    assert %{dir: ^dir, run_id: "run", prior: :unreadable} =
             Candidates.claim!(root, "run", "a_journey", "en")

    assert File.ls!(dir) == [".claim"]
  end
end

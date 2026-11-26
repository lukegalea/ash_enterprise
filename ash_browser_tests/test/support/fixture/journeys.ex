defmodule AshBrowserTests.Fixture.JourneySurfaces do
  @moduledoc false
  @behaviour AshJourneys.SurfaceRegistry

  @impl true
  def surface(:widgets), do: %{ui: AshBrowserTests.Fixture.Widget}
  def surface(:whoami), do: %{ui: nil}
  def surface(:console_error), do: %{ui: nil}
  def surface(_id), do: nil
end

defmodule AshBrowserTests.Fixture.JourneyPersonas do
  @moduledoc false
  @behaviour AshJourneys.Persona

  @impl true
  def actor(role, _name, _bindings), do: {:ok, Atom.to_string(role)}
end

defmodule AshBrowserTests.Fixture.JourneyWorld do
  @moduledoc false
  # Every binding is a widget, created under the name its reference gives.
  @behaviour AshJourneys.World

  alias AshBrowserTests.Fixture.Widget

  @impl true
  def seed(world, _opts) do
    {:ok,
     Map.new(world.bind, fn {binding, {:widget, name}} ->
       widget =
         Widget
         |> Ash.Changeset.for_create(:create, %{name: name})
         |> Ash.create!(authorize?: false)

       {binding, widget}
     end)}
  end

  @impl true
  def pin_timestamps(_bindings, _clock, _pins), do: :ok
end

defmodule AshBrowserTests.Fixture.JourneyHost do
  @moduledoc false
  @behaviour AshBrowserTests.Journeys.Host

  alias AshBrowserTests.Browser
  alias AshBrowserTests.Fixture.Endpoint

  @impl true
  def path(:widgets, _bindings), do: "/journey/widgets"
  def path(:whoami, _bindings), do: "/whoami"
  def path(:console_error, _bindings), do: "/console-error"

  @impl true
  def sign_in(conn, actor, _context) do
    Browser.sign_in(conn, %{"user" => actor}, Endpoint.session_options())
  end

  @impl true
  def manifest_opts(locale), do: [catalog: :admin_v1, locale: locale]

  @impl true
  def mask(:as_of), do: "#as-of"

  # The fixture has no audit table: the test is told what the runner asked
  # about, and checks it is what the step traced and did.
  @impl true
  def assert_audit(correlation_id, acted, _context) do
    send(self(), {:audit_asserted, correlation_id, acted})
    :ok
  end
end

defmodule AshBrowserTests.Fixture.Journeys do
  @moduledoc false
  # Journeys that pass: the generated suite runs every one of them.
  use AshJourneys.Journeys,
    surfaces: AshBrowserTests.Fixture.JourneySurfaces,
    personas: AshBrowserTests.Fixture.JourneyPersonas,
    world: AshBrowserTests.Fixture.JourneyWorld

  journey :activate_a_widget do
    version(1)
    kind(:how_to)
    title("Activate a widget")
    goal("The widget is active.")
    outcome("The widget is active, and the viewer saw it happen.")
    locales([:en])

    persona(:viewer, :viewer)
    persona(:admin, :admin)
    world(bind: [widget: {:widget, "Sprocket"}])

    step :viewer_sees_the_widgets, as: :viewer do
      open(:widgets)
      say("The viewer sees the widgets.")
      expect(trace: [:live_mount, {:ash_action, :read}])
      figure(:widgets, mask: [{:as_of, width: "6rem"}])
    end

    step :activate, as: :admin do
      open(:widgets)
      row_action("widgets.activate", on: :widget)
      say("Choose %{action}.", action: ui({:row_action, "widgets.activate"}))

      expect(
        trace: [:handle_event, {:ash_action, :activate}],
        one_correlation: true,
        audit: true
      )

      expect(record: {:widget, active: true})

      figure(:activated,
        frame: {:table, "widgets"},
        highlight: {:row, :widget},
        mask: [{:as_of, width: "6rem"}]
      )
    end
  end

  journey :remove_a_widget do
    version(1)
    kind(:how_to)
    title("Remove a widget")
    goal("The widget is gone.")
    outcome("The widget no longer appears.")
    locales([:en])

    persona(:admin, :admin)
    world(bind: [widget: {:widget, "Gizmo"}])

    step :remove, as: :admin do
      open(:widgets)
      row_action("widgets.remove", on: :widget, confirm: true)
      figure(:confirm, frame: :dialog)
      say("Choose %{action} and confirm.", action: ui({:row_action, "widgets.remove"}))
      expect(trace: [:handle_event, {:ash_action, :remove}])
      figure(:removed, mask: [{:as_of, width: "6rem"}])
    end
  end
end

defmodule AshBrowserTests.Fixture.MoreJourneys do
  @moduledoc false
  # Journeys the tests run by hand: ones that must fail, and one run as a retry.
  use AshJourneys.Journeys,
    surfaces: AshBrowserTests.Fixture.JourneySurfaces,
    personas: AshBrowserTests.Fixture.JourneyPersonas,
    world: AshBrowserTests.Fixture.JourneyWorld

  journey :stops_at_a_failing_step do
    version(1)
    kind(:how_to)
    title("Stops at a failing step")
    goal("Nothing after the failing step runs.")
    outcome("The widget stays inactive.")
    locales([:en])

    persona(:viewer, :viewer)
    persona(:admin, :admin)
    world(bind: [widget: {:widget, "Sprocket"}])

    step :expects_too_soon, as: :viewer do
      open(:whoami)
      say("The widget is already active, it claims.")
      expect(record: {:widget, active: true})
    end

    step :activate, as: :admin do
      open(:widgets)
      row_action("widgets.activate", on: :widget)
      say("Choose %{action}.", action: ui({:row_action, "widgets.activate"}))
      expect(trace: [:handle_event, {:ash_action, :activate}])
    end
  end

  journey :loses_a_span do
    version(1)
    kind(:how_to)
    title("Loses a span")
    goal("A span lost in the second step fails the second step.")
    outcome("The third step never runs.")
    locales([:en])

    persona(:admin, :admin)
    persona(:viewer, :viewer)
    world(bind: [first: {:widget, "Sprocket"}, second: {:widget, "Untraced sprocket"}])

    step :activate_the_first, as: :admin do
      open(:widgets)
      row_action("widgets.activate", on: :first)
      say("Choose %{action}.", action: ui({:row_action, "widgets.activate"}))
      expect(trace: [:handle_event, {:ash_action, :activate}])
    end

    step :activate_the_second, as: :admin do
      row_action("widgets.activate", on: :second)
      say("Choose %{action} again.", action: ui({:row_action, "widgets.activate"}))
      expect(trace: [:handle_event, {:ash_action, :activate}])
    end

    step :viewer_looks, as: :viewer do
      open(:whoami)
      say("The viewer looks.")
    end
  end

  journey :meets_a_console_error do
    version(1)
    kind(:how_to)
    title("Meets a console error")
    goal("A browser failure fails the step it happened in.")
    outcome("The step is failed, and the run is not passed.")
    locales([:en])

    persona(:viewer, :viewer)
    persona(:admin, :admin)

    step :viewer_looks, as: :viewer do
      open(:whoami)
      say("The viewer looks.")
    end

    step :admin_opens_a_broken_page, as: :admin do
      open(:console_error)
      say("The administrator opens a page that logs an error.")
    end
  end

  journey :audits_without_a_row_action do
    version(1)
    kind(:how_to)
    title("Audits without a row action")
    goal("An audit expectation needs an action whose row to find.")
    outcome("The step fails.")
    locales([:en])

    persona(:viewer, :viewer)

    step :viewer_looks, as: :viewer do
      open(:widgets)
      say("The viewer looks.")
      expect(trace: [:live_mount], audit: true)
    end
  end

  journey :passes_on_a_retry do
    version(1)
    kind(:how_to)
    title("Passes on a retry")
    goal("The viewer sees the widgets.")
    outcome("The viewer sees the widgets.")
    locales([:en])

    persona(:viewer, :viewer)

    step :viewer_sees_the_widgets, as: :viewer do
      open(:widgets)
      say("The viewer sees the widgets.")
      expect(trace: [:live_mount, {:ash_action, :read}])
    end
  end
end

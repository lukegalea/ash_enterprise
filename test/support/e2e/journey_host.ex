defmodule AshEnterpriseWeb.E2E.JourneyHost do
  @moduledoc """
  What the browser tier needs to walk this application's journeys
  (`AshBrowserTests.Journeys.Host`), beside what the journey modules already name
  (`AshEnterprise.Journeys.Surfaces`, `Personas` and `World`).

    * A persona signs in through the session cookie (`AshEnterpriseWeb.E2E.Login`),
      in a browser context whose locale is the journey's; the app answers in that
      context's language (`AshEnterpriseWeb.Locale`, from `Accept-Language`).
    * Surfaces render in the locale the run is in, so row actions are found by
      the labels the reader sees.
    * `:as_of` is the page header's "As of" time, the one request-time label on a
      surface page. It cannot be pinned by a seed, so a figure masks it.
    * What the pseudo-locale run does not count as untranslated: the product's
      name, the seeded organization's, the command palette's key hint, and each
      seeded person's email and creation time.
    * The audit proof: the `audit_events` row the step's row action wrote, by its
      action on its resource, about the record it acted on, with the step's
      correlation id and no earlier than the step began. A LiveView keeps one
      correlation id for its whole life (`AshEnterprise.Platform.TelemetryCorrelation`),
      so the correlation id alone would also find an earlier step's rows.
  """

  @behaviour AshBrowserTests.Journeys.Host

  import ExUnit.Assertions

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Journeys.Surfaces
  alias AshEnterprise.Journeys.World
  alias AshEnterpriseWeb.E2E.Login

  @impl true
  def path(surface, _bindings), do: Surfaces.path(surface)

  @impl true
  def sign_in(conn, user, _context), do: Login.as(conn, %{user: user})

  @impl true
  def manifest_opts(locale), do: AshEnterpriseWeb.Locale.a2ui_opts(locale)

  @impl true
  def mask(:as_of), do: ~s([id$="-as-of"])

  @impl true
  def visible_data(bindings) do
    [AshEnterprise.Brand.product_name(), World.organization_name(), "ctrl p"] ++
      Enum.flat_map(bindings, &record_data/1)
  end

  # A person is their email, and the instant their row was created, as the
  # surface formats it: the pseudo-locale has no date formats of its own.
  defp record_data({_binding, %{email: email} = user}) do
    created = user |> Ash.reload!(authorize?: false) |> Map.fetch!(:created_on)
    [to_string(email), Calendar.strftime(created, "%b %-d, %Y, %H:%M")]
  end

  defp record_data(_other), do: []

  @impl true
  def assert_audit(correlation_id, %{record: %{id: record_id}} = acted, _context) do
    events =
      EventLog
      |> Ash.Query.filter(correlation_id == ^correlation_id)
      |> Ash.read!(authorize?: false)

    assert Enum.any?(events, &proves?(&1, acted)),
           "no audit row for #{inspect(acted.resource)}.#{acted.action} on #{record_id} " <>
             "with correlation id #{correlation_id} since #{DateTime.to_iso8601(acted.since)}; " <>
             "rows with that correlation id: " <>
             inspect(Enum.map(events, &{&1.resource, &1.action, &1.record_id, &1.occurred_at}))
  end

  defp proves?(event, %{resource: resource, action: action, record: %{id: id}, since: since}) do
    event.resource == resource and event.action == action and event.record_id == id and
      DateTime.compare(event.occurred_at, since) != :lt
  end
end

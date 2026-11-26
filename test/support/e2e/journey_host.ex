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
    * The audit proof: an `audit_events` row with the step's correlation id, for
      one of the world's bound records.
  """

  @behaviour AshBrowserTests.Journeys.Host

  import ExUnit.Assertions

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Journeys.Surfaces
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
  def assert_audit(correlation_id, %{bindings: bindings}) do
    ids = for {_binding, %{id: id}} <- bindings, do: id

    events =
      EventLog
      |> Ash.Query.filter(correlation_id == ^correlation_id)
      |> Ash.read!(authorize?: false)

    assert Enum.any?(events, &(&1.record_id in ids)),
           "no audit row with correlation id #{correlation_id} for a bound record; " <>
             "rows with that correlation id: " <>
             inspect(Enum.map(events, &{&1.resource, &1.action, &1.record_id}))
  end
end

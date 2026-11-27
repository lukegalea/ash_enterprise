defmodule AshEnterpriseWeb.E2E.JourneysTest do
  @moduledoc """
  Every journey this application declares, walked in a real browser in each of
  its locales (`AshBrowserTests.Journeys`). Each test writes a run manifest and
  its figures under `tmp/journeys/runs/`; `mix ash_journeys.approve <run-id>`
  publishes a run that passed every step on its first attempt.

  Each journey also runs once in the pseudo-locale (`AshEnterpriseWeb.Locale.pseudo/0`),
  and fails on any visible English in a figured region outside its masks; that run is
  never approvable.

  The tests of one module run one after another, so the en and fr runs of a
  journey never seed the same people at once.
  """

  use AshBrowserTests.Journeys,
    host: AshEnterpriseWeb.E2E.JourneyHost,
    journeys: Application.compile_env!(:ash_journeys, :journeys),
    pseudo_locale: Application.compile_env!(:ash_enterprise, :pseudo_locale),
    async: true
end

defmodule AshEnterpriseWeb.E2E.JourneysTest do
  @moduledoc """
  Every journey this application declares, walked in a real browser in each of
  its locales (`AshBrowserTests.Journeys`). Each test writes a run manifest and
  its figures under `tmp/journeys/runs/`; `mix ash_journeys.approve <run-id>`
  publishes a run that passed every step on its first attempt.

  The tests of one module run one after another, so the en and fr runs of a
  journey never seed the same people at once.
  """

  use AshBrowserTests.Journeys,
    host: AshEnterpriseWeb.E2E.JourneyHost,
    journeys: Application.compile_env!(:ash_journeys, :journeys),
    async: true
end

defmodule AshBrowserTests.Journeys.Host do
  @moduledoc """
  What a host provides to run its journeys in a browser
  (`AshBrowserTests.Journeys`).

  A journey module already names the host's surface registry, personas and
  world (`AshJourneys.Journeys`); this is the part only a browser needs. Every
  `context` below is the test's ExUnit context, plus `:locale` (the journey's
  locale, a string), `:persona` (the persona's name) and `:bindings` (the
  world's bound records by binding name).
  """

  @doc "The path that opens surface `surface`, for `open` and `expect lands_on:`."
  @callback path(surface :: atom(), bindings :: %{atom() => term()}) :: String.t()

  @doc """
  Signs the browser session `conn` in as `actor`, the one
  `c:AshJourneys.Persona.actor/3` returned for the persona, and returns it. The
  persona's browser context already has the journey's locale
  (`AshBrowserTests.Journeys.framing/1`).
  """
  @callback sign_in(conn :: struct(), actor :: term(), context :: map()) :: struct()

  @doc """
  The options a surface renders with in `locale` (`:catalog`, `:locale`,
  `:gettext_backend`, …), for `AshA2ui.Manifest.for_surface/2` and the
  start-of-run check (`AshJourneys.Preflight.check/3`), so row actions are
  found by the labels the reader sees.
  """
  @callback manifest_opts(locale :: String.t()) :: keyword()

  @doc """
  The CSS selector of a masked region a journey's figure names
  (`mask: [{:as_of, width: "6rem"}]`). A plain CSS selector, not a Playwright
  one: it also styles the region to its fixed width for the capture.
  """
  @callback mask(region :: atom()) :: String.t()

  @doc """
  Asserts the audit rows correlation id `correlation_id` wrote, for
  `expect audit: true`. Raises `ExUnit.AssertionError` when there are none.
  """
  @callback assert_audit(correlation_id :: String.t(), context :: map()) :: any()

  @optional_callbacks mask: 1, assert_audit: 2
end

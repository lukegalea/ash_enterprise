defmodule AshBrowserTests.Case do
  @moduledoc """
  The case template for a browser test.

      defmodule MyAppWeb.E2E.CheckoutTest do
        use AshBrowserTests.Case, async: true

        test "the event reaches the database", %{conn: conn, test_key: key} do
          conn
          |> sign_in(%{"user_token" => token()}, MyAppWeb.Endpoint.session_options())
          |> visit("/orders")
          |> assert_connected()
          |> click_button("Create")

          assert_chain(key, [browser_event(), handle_event(), ash_action(), query()])
        end
      end

  It adds to `PhoenixTest.Playwright.Case`:

    * the `:e2e` tag (`:browser` collides with the Playwright context option);
    * `:test_key` in the context, set on the test process too, so spans the test
      itself starts (and jobs it drains) carry it;
    * failure capture: a console error, page error or 5xx not consumed by the test
      fails it at exit. `@tag allow_browser_failures: true` opts a test out;
    * `AshBrowserTests.Browser` and `AshBrowserTests.Trace` imported.

  Options are those of `PhoenixTest.Playwright.Case`.
  """

  alias AshBrowserTests.Browser
  alias AshBrowserTests.FailureCapture
  alias AshBrowserTests.TestKey

  defmacro __using__(opts) do
    quote do
      use PhoenixTest.Playwright.Case, unquote(opts)

      @moduletag :e2e

      import AshBrowserTests.Browser
      import AshBrowserTests.Trace

      setup {AshBrowserTests.Case, :setup_test}
    end
  end

  @doc false
  def setup_test(context) do
    key = TestKey.from_owner(self())
    TestKey.put(key)

    capture = FailureCapture.start!(context.conn)
    Browser.put_capture(capture)
    strict? = not Map.get(context, :allow_browser_failures, false)

    ExUnit.Callbacks.on_exit(fn ->
      failures = FailureCapture.stop(capture)

      if strict? and failures != [] do
        raise ExUnit.AssertionError, message: FailureCapture.format(failures)
      end
    end)

    [test_key: key, browser_failures: capture]
  end
end

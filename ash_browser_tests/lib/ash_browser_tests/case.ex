defmodule AshBrowserTests.Case do
  @moduledoc """
  The case template for a browser test.

      defmodule MyAppWeb.E2E.CheckoutTest do
        use AshBrowserTests.Case, async: true

        test "the event reaches the database", %{conn: conn, test_key: key} do
          conn
          |> sign_in(%{"user_token" => token()}, MyAppWeb.Endpoint.session_options())
          |> visit("/orders")
          |> click_button("Create")

          assert_chain(key, [browser_event(), handle_event(), ash_action(), query()])
        end
      end

  It adds to `Playwright.Test` and Fluffy's PhoenixTest facade (`Fluffy.PhoenixTest`):

    * the `:e2e` tag (`:browser` collides with the Playwright context option);
    * `:conn`, a Playwright session, with the Ecto sandbox owned for the
      repositories of `config :fluffy, ecto_repos: [...]`;
    * `:test_key` in the context, set on the test process too, so spans the test
      itself starts (and jobs it drains) carry it;
    * failure capture: a console error, page error or 5xx not consumed by the test
      fails it at exit. `@tag allow_browser_failures: true` opts a test out;
    * `AshBrowserTests.Browser` and `AshBrowserTests.Trace` imported.

  Options are those of `ExUnit.Case` and `Playwright.Test`.
  """

  alias AshBrowserTests.Browser
  alias AshBrowserTests.FailureCapture
  alias AshBrowserTests.TestKey

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(Keyword.take(opts, [:async, :group, :parameterize]))
      use Playwright.Test, unquote(opts)

      @moduletag :e2e

      import Fluffy.PhoenixTest
      import AshBrowserTests.Browser
      import AshBrowserTests.Trace

      setup {AshBrowserTests.Case, :setup_test}
    end
  end

  @doc false
  def setup_test(context) do
    for repo <- Application.get_env(:fluffy, :ecto_repos, []) do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: not context[:async])
      ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    end

    conn = Fluffy.PhoenixTest.start_session(:playwright)

    key = TestKey.from_owner(self())
    TestKey.put(key)

    capture = FailureCapture.start!(conn)
    Browser.put_capture(capture)
    strict? = not Map.get(context, :allow_browser_failures, false)

    ExUnit.Callbacks.on_exit(fn ->
      failures = FailureCapture.stop(capture)

      if strict? and failures != [] do
        raise ExUnit.AssertionError, message: FailureCapture.format(failures)
      end
    end)

    [conn: conn, test_key: key, browser_failures: capture]
  end
end

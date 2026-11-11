defmodule AshBrowserTests.Browser do
  @moduledoc """
  Helpers for driving a page: session-cookie sign-in, assertions that see through
  shadow roots, and console and 5xx failure checks.

  PhoenixTest's own helpers are unaffected. Use these where a selector must cross a
  shadow boundary that Playwright's own CSS does not pierce from your starting
  point, or where the assertion is about the composed tree as a whole.
  """

  alias AshBrowserTests.FailureCapture
  alias PhoenixTest.Playwright

  @capture_key {__MODULE__, :failure_capture}

  @walker """
  const deep = (root, selector, found = []) => {
    for (const el of root.querySelectorAll("*")) {
      if (el.matches(selector)) found.push(el)
      if (el.shadowRoot) deep(el.shadowRoot, selector, found)
    }
    return found
  }
  """

  @doc "The JavaScript that defines `deep(root, selector)`, for hand-written `evaluate` calls."
  @spec walker() :: String.t()
  def walker, do: @walker

  # --- Sign-in ---------------------------------------------------------------------

  @doc """
  Puts `session` in the browser's signed session cookie, for hosts whose LiveView
  and controller sessions read it.

      sign_in(conn, %{"user_token" => token}, MyAppWeb.Endpoint.session_options())
  """
  @spec sign_in(struct(), map(), keyword()) :: struct()
  def sign_in(conn, session, session_options) when is_map(session) do
    Playwright.add_session_cookie(conn, [value: session], session_options)
  end

  # --- Connection ------------------------------------------------------------------

  @doc "Asserts the LiveView on the page has joined its channel."
  @spec assert_connected(struct(), keyword()) :: struct()
  def assert_connected(conn, opts \\ []) do
    PhoenixTest.assert_has(conn, "body .phx-connected",
      timeout: Keyword.get(opts, :timeout, 15_000)
    )
  end

  @doc """
  Ends the browser's connect span and flushes pending browser spans, if the page's
  tracer exposes `window.__otelEndConnect` and `window.__otelFlush`.
  """
  @spec flush_browser_spans(struct()) :: struct()
  def flush_browser_spans(conn) do
    Playwright.evaluate(conn, """
    (() => {
      if (window.__otelEndConnect) window.__otelEndConnect()
      if (window.__otelFlush) window.__otelFlush()
    })()
    """)
  end

  # --- The composed tree -----------------------------------------------------------

  @doc "The elements matching `selector` in the document and every open shadow root below it."
  @spec deep_query(struct(), String.t()) :: [map()]
  def deep_query(conn, selector) do
    eval(conn, """
    (() => {
      #{@walker}
      return deep(document, #{Jason.encode!(selector)}).map((el) => ({
        tag: el.tagName.toLowerCase(),
        text: el.textContent.trim().replace(/\\s+/g, " ")
      }))
    })()
    """)
  end

  @doc "How many elements match `selector` across shadow roots."
  @spec deep_count(struct(), String.t()) :: non_neg_integer()
  def deep_count(conn, selector), do: length(deep_query(conn, selector))

  @doc """
  Waits for `selector` to match across shadow roots. Options: `:text` (substring or
  regex), `:count` (exact), `:timeout` (default 5000).
  """
  @spec assert_deep(struct(), String.t(), keyword()) :: struct()
  def assert_deep(conn, selector, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
    wait_deep(conn, selector, opts, deadline)
  end

  @doc "Asserts nothing matches `selector` across shadow roots, right now."
  @spec refute_deep(struct(), String.t(), keyword()) :: struct()
  def refute_deep(conn, selector, opts \\ []) do
    matches = conn |> deep_query(selector) |> filter_text(opts[:text])

    if matches != [] do
      raise ExUnit.AssertionError,
        message: "expected nothing to match #{selector}, found: #{inspect(matches)}"
    end

    conn
  end

  @doc """
  Clicks the first element matching `selector` across shadow roots, optionally only
  one whose text contains `:text`. A host element's inner `button` receives the click.
  """
  @spec deep_click(struct(), String.t(), keyword()) :: struct()
  def deep_click(conn, selector, opts \\ []) do
    text = Keyword.get(opts, :text)

    clicked =
      eval(conn, """
      (() => {
        #{@walker}
        const text = #{Jason.encode!(text)}
        const el = deep(document, #{Jason.encode!(selector)}).find((candidate) =>
          text === null || candidate.textContent.includes(text))
        if (!el) return false
        const inner = el.shadowRoot && el.shadowRoot.querySelector("button")
        ;(inner || el).click()
        return true
      })()
      """)

    if clicked != true do
      raise ExUnit.AssertionError,
        message: "no element matches #{selector}" <> if(text, do: " with text #{text}", else: "")
    end

    conn
  end

  defp wait_deep(conn, selector, opts, deadline) do
    matches = conn |> deep_query(selector) |> filter_text(opts[:text])
    expected = Keyword.get(opts, :count)

    cond do
      satisfied?(matches, expected) ->
        conn

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(50)
        wait_deep(conn, selector, opts, deadline)

      true ->
        raise ExUnit.AssertionError,
          message:
            "expected #{expected || "at least one"} element(s) to match #{selector}" <>
              if(opts[:text], do: " with text #{inspect(opts[:text])}", else: "") <>
              ", found #{length(matches)}"
    end
  end

  defp satisfied?(matches, nil), do: matches != []
  defp satisfied?(matches, expected), do: length(matches) == expected

  defp filter_text(matches, nil), do: matches

  defp filter_text(matches, %Regex{} = regex) do
    Enum.filter(matches, &Regex.match?(regex, &1["text"]))
  end

  defp filter_text(matches, text) when is_binary(text) do
    Enum.filter(matches, &String.contains?(&1["text"], text))
  end

  defp eval(conn, expression) do
    parent = self()
    ref = make_ref()
    Playwright.evaluate(conn, expression, fn result -> send(parent, {ref, result}) end)

    receive do
      {^ref, result} -> result
    after
      5_000 -> raise ExUnit.AssertionError, message: "the page did not answer evaluate"
    end
  end

  # --- Failure capture --------------------------------------------------------------

  @doc false
  def put_capture(capture), do: Process.put(@capture_key, capture)

  @doc false
  def capture, do: Process.get(@capture_key)

  @doc """
  The browser failures recorded so far in this test: console errors, uncaught page
  errors and 5xx responses, each a map with `:type`, `:text` and, where known, `:url`.
  """
  @spec browser_failures(struct()) :: [FailureCapture.failure()]
  def browser_failures(conn) do
    Playwright.evaluate(conn, "1")
    capture() |> FailureCapture.failures()
  end

  @doc """
  Asserts the browser reported no console error, page error or 5xx. Options:
  `:allow`, a list of regexes over each failure's text and URL.
  """
  @spec assert_no_browser_failures(struct(), keyword()) :: struct()
  def assert_no_browser_failures(conn, opts \\ []) do
    conn
    |> browser_failures()
    |> reject_allowed(Keyword.get(opts, :allow, []))
    |> case do
      [] ->
        conn

      failures ->
        raise ExUnit.AssertionError, message: FailureCapture.format(failures)
    end
  end

  @doc """
  Consumes the failures matching `pattern` (a regex over text and URL) and returns
  them, so an expected failure does not fail the test at exit.
  """
  @spec take_browser_failures(struct(), Regex.t()) :: [FailureCapture.failure()]
  def take_browser_failures(conn, %Regex{} = pattern) do
    Playwright.evaluate(conn, "1")
    capture() |> FailureCapture.take(pattern)
  end

  defp reject_allowed(failures, []), do: failures

  defp reject_allowed(failures, allowed) do
    Enum.reject(failures, fn failure ->
      Enum.any?(allowed, &FailureCapture.matches?(failure, &1))
    end)
  end
end

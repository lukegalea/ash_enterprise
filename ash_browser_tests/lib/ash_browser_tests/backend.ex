defmodule AshBrowserTests.Backend do
  @moduledoc """
  One API over the places spans can be read from.

      {:ok, spans} = AshBrowserTests.Backend.spans_for(key, 5_000)

  The key is a test key (the default selector, `AshBrowserTests.TestKey`), or
  `{:trace_id, hex}`, or `{:correlation_id, id}` where a backend supports it.
  Selection is always by key: the OpenTelemetry pipeline is global, so nothing
  here reads "the last trace" or clears anything.

  The backend comes from `config :ash_browser_tests, :backend`, default
  `AshBrowserTests.Backend.TraceSink`, or from the `:backend` option:

      Backend.spans_for({:trace_id, hex}, 30_000, backend: Backend.SigNoz)

  ## Implementing one

  `c:spans_for/2` is called with `timeout` removed and answers immediately; polling
  lives here.
  """

  alias AshBrowserTests.Span

  @type key :: String.t() | {:trace_id, String.t()} | {:correlation_id, String.t()}

  @callback spans_for(key(), keyword()) :: {:ok, [Span.t()]} | {:error, term()}

  @poll_ms 20

  @doc """
  The spans for `key`, waiting up to `timeout` milliseconds for at least one.
  An empty list after the timeout is a success: nothing was recorded for that key.
  """
  @spec spans_for(key(), non_neg_integer(), keyword()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def spans_for(key, timeout \\ 5_000, opts \\ []) do
    backend = backend(opts)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(backend, key, opts, deadline)
  end

  @doc "The backend named in `opts`, or the configured one."
  @spec backend(keyword()) :: module()
  def backend(opts \\ []) do
    Keyword.get_lazy(opts, :backend, fn ->
      Application.get_env(:ash_browser_tests, :backend, AshBrowserTests.Backend.TraceSink)
    end)
  end

  defp poll(backend, key, opts, deadline) do
    result = backend.spans_for(key, opts)

    cond do
      match?({:ok, [_ | _]}, result) ->
        result

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(Keyword.get(opts, :poll_ms, @poll_ms))
        poll(backend, key, opts, deadline)

      true ->
        result
    end
  end
end

defmodule AshBrowserTests.FailureCapture do
  @moduledoc """
  Records what the browser reports going wrong during one test: console errors,
  uncaught page errors and 5xx responses.

  Started by `AshBrowserTests.Case`. A failure not consumed with
  `AshBrowserTests.Browser.take_browser_failures/2` fails the test at exit, unless
  the test is tagged `@tag allow_browser_failures: true`.
  """

  use GenServer

  alias Fluffy.Event
  alias Playwright.ConsoleMessage
  alias Playwright.Response

  @type failure :: %{
          required(:type) => :console | :page_error | :http_5xx,
          required(:text) => String.t(),
          optional(:url) => String.t(),
          optional(:status) => pos_integer()
        }

  @doc "Starts capturing for a Playwright session. Not linked, so it outlives the test process."
  @spec start!(struct()) :: pid()
  def start!(conn) do
    {:ok, pid} = GenServer.start(__MODULE__, nil)

    for event <- [Event.console(), Event.page_error(), Event.response()] do
      Fluffy.on(conn, event, &send(pid, {:playwright_event, &1}))
    end

    pid
  end

  @doc "The recorded failures, oldest first."
  @spec failures(pid()) :: [failure()]
  def failures(capture), do: GenServer.call(capture, :failures)

  @doc "Removes and returns the failures matching `pattern`."
  @spec take(pid(), Regex.t()) :: [failure()]
  def take(capture, %Regex{} = pattern), do: GenServer.call(capture, {:take, pattern})

  @doc "Stops the capture and returns the failures it holds."
  @spec stop(pid()) :: [failure()]
  def stop(capture), do: GenServer.call(capture, :stop)

  @doc "Whether a failure's text or URL matches `pattern`."
  @spec matches?(failure(), Regex.t()) :: boolean()
  def matches?(failure, %Regex{} = pattern) do
    Regex.match?(pattern, failure.text) or Regex.match?(pattern, Map.get(failure, :url, ""))
  end

  @doc "A failure message listing `failures`."
  @spec format([failure()]) :: String.t()
  def format(failures) do
    "the browser reported failures:\n" <>
      Enum.map_join(failures, "\n", fn failure ->
        "  #{failure.type}: #{failure.text}" <>
          if(failure[:url], do: " (#{failure.url})", else: "")
      end)
  end

  @impl GenServer
  def init(nil), do: {:ok, %{failures: []}}

  @impl GenServer
  def handle_call(:failures, _from, state), do: {:reply, Enum.reverse(state.failures), state}

  def handle_call({:take, pattern}, _from, state) do
    {taken, kept} = Enum.split_with(state.failures, &matches?(&1, pattern))
    {:reply, Enum.reverse(taken), %{state | failures: kept}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, Enum.reverse(state.failures), state}
  end

  @impl GenServer
  def handle_info({:playwright_event, event}, state) do
    {:noreply, record(state, event)}
  rescue
    # Never let a surprising message shape crash the capture.
    _error -> {:noreply, state}
  catch
    :exit, _reason -> {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp record(state, %ConsoleMessage{} = message) do
    if ConsoleMessage.type(message) in ["error", "assert"] do
      url = location(ConsoleMessage.location(message))

      # Every page without an icon link logs this once; it says nothing about the page.
      if url != nil and String.ends_with?(url, "/favicon.ico") do
        state
      else
        add(state, %{type: :console, text: ConsoleMessage.text(message), url: url})
      end
    else
      state
    end
  end

  defp record(state, %Response{} = response) do
    status_failure(state, response, Response.status(response))
  end

  defp record(state, error) when is_exception(error) do
    add(state, %{type: :page_error, text: Exception.message(error)})
  end

  defp record(state, _event), do: state

  defp status_failure(state, response, status) when status >= 500 do
    add(state, %{
      type: :http_5xx,
      text: "HTTP #{status}",
      status: status,
      url: Response.url(response)
    })
  end

  defp status_failure(state, _response, _status), do: state

  defp add(state, failure) do
    failure = failure |> Enum.reject(fn {_k, v} -> v in [nil, ""] end) |> Map.new()
    %{state | failures: [failure | state.failures]}
  end

  defp location(%{url: url}) when is_binary(url), do: url
  defp location(_location), do: nil
end

defmodule AshBrowserTests.Reporter do
  @moduledoc """
  An ExUnit formatter that records what each browser test did, so the media it
  left behind can be presented as a report.

  `phoenix_test_playwright` writes a screenshot and a trace per test, named from
  the ExUnit context — `Module.test_name_<unix seconds>` with everything outside
  `[a-zA-Z0-9.]` replaced by `_`. Those files are all a reader gets: the names
  carry no outcome, no duration and no failure message, and nothing says whether
  the twenty screenshots in a directory are twenty passes or nineteen passes and
  the one you are looking for.

  This formatter records the outcome under the same key the driver names files
  with (`key/2`), which is what lets `mix ash_browser_tests.report` join them.

  ## Using it

      # test/test_helper.exs
      ExUnit.start(formatters: [ExUnit.CLIFormatter, AshBrowserTests.Reporter])

  It is harmless in a suite with no browser tests: it records whatever ran and
  the report task simply finds no media for those tests.

  ## Where it writes

  `config :ash_browser_tests, report_path: "tmp/playwright/results.json"` is the
  default. Written once, on `:suite_finished`, so a killed run leaves no
  half-file for the task to misread.

  The file is a report of a test run and nothing else: no parameters, no assigns,
  no span attributes. Failure text is truncated (`@failure_bytes`), because an
  ExUnit failure can carry a whole rendered page and this ends up in a CI
  artifact.
  """

  use GenServer

  @failure_bytes 2_000
  @default_path "tmp/playwright/results.json"

  @doc """
  The media name the Playwright driver derives for a test, without the timestamp
  it appends.

  Kept identical to `PhoenixTest.Playwright.Case`'s private `file_name/2` — the
  join depends on it, and there is no public function to call instead. If a
  driver upgrade changes the convention, the report shows tests with no media
  rather than failing, and `AshBrowserTests.ReporterTest` pins the format.
  """
  @spec key(module(), atom() | String.t()) :: String.t()
  def key(module, test_name) do
    module = module |> to_string() |> String.replace_prefix("Elixir.", "")

    String.replace("#{module}.#{test_name}", ~r/[^a-zA-Z0-9\.]/, "_")
  end

  @doc "Where this run's results are written."
  @spec path() :: String.t()
  def path, do: Application.get_env(:ash_browser_tests, :report_path, @default_path)

  @impl GenServer
  def init(_opts), do: {:ok, %{tests: []}}

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, %{state | tests: [record(test) | state.tests]}}
  end

  @impl GenServer
  def handle_cast({:suite_finished, _times}, state) do
    write(state.tests)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(_event, state), do: {:noreply, state}

  defp record(%ExUnit.Test{} = test) do
    %{
      key: key(test.module, test.name),
      module: test.module |> to_string() |> String.replace_prefix("Elixir.", ""),
      name: to_string(test.name),
      status: status(test.state),
      # Microseconds, as ExUnit reports it. Left in that unit rather than
      # rounded to milliseconds: the fast generated surface tests would all
      # become "0ms" and the report would stop being able to show an outlier.
      time_us: test.time,
      failure: failure(test.state),
      journey: journey(test.tags[:journey])
    }
  end

  # A journey test (`AshBrowserTests.Journeys`) is tagged with what it runs, so
  # the report can group the journey's locales together.
  defp journey({_module, name, locale}), do: %{id: to_string(name), locale: locale}
  defp journey(_not_a_journey), do: nil

  defp status(nil), do: "passed"
  defp status({:failed, _failures}), do: "failed"
  defp status({:invalid, _module}), do: "invalid"
  defp status({:skipped, _reason}), do: "skipped"
  defp status({:excluded, _reason}), do: "excluded"
  defp status(_other), do: "unknown"

  # ExUnit's own formatter needs a width and a counter to render a failure. This
  # only wants the first line or two for a summary table, so it takes the
  # message off each failure and leaves the stacktrace alone.
  defp failure({:failed, failures}) do
    failures
    |> Enum.map_join("\n", &message/1)
    |> String.slice(0, @failure_bytes)
  end

  defp failure(_state), do: nil

  defp message({_kind, %{message: message}, _stack}) when is_binary(message), do: message
  defp message({_kind, %ExUnit.AssertionError{} = error, _stack}), do: inspect(error.message)
  defp message({_kind, reason, _stack}), do: inspect(reason)

  defp write(tests) do
    path = path()
    File.mkdir_p!(Path.dirname(path))

    payload = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      tests: Enum.sort_by(tests, & &1.key)
    }

    File.write!(path, Jason.encode_to_iodata!(payload))
  end
end

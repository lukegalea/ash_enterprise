defmodule Mix.Tasks.AshBrowserTests.Report do
  @shortdoc "Turns a browser run's screenshots and traces into one HTML page"

  @moduledoc """
  Builds a self-contained report from what a browser run left in
  `screenshot_dir` and `trace_dir`.

      mix ash_browser_tests.report

  Writes `index.html` next to the media, and — when `GITHUB_STEP_SUMMARY` is set
  — a markdown table to that file.

  Options:

    * `--screenshots DIR` - default: the `:screenshot_dir` the host configured
      for `:phoenix_test`, else `screenshots`
    * `--traces DIR` - default: the configured `:trace_dir`, else `traces`
    * `--results PATH` - `AshBrowserTests.Reporter`'s output. Default:
      `:report_path`. Absent is fine; the report then lists media with no outcome
    * `--out DIR` - where `index.html` goes. Default: the nearest common parent
      of the media directories, so its links can be relative
    * `--summary PATH` - write the markdown summary here instead of
      `GITHUB_STEP_SUMMARY`
    * `--title TEXT` - heading for the page

  ## Why a page and not just the artifact

  An artifact of loose PNGs and trace zips answers "what did the browser see?"
  only after you unzip it and guess which file is the test you care about. The
  names carry no outcome, so a directory of twenty screenshots looks the same
  whether the run was green or not. One page with a row per test — status,
  duration, screenshot, trace — is readable at the size the suite is heading
  for, where surfaces, tables, presets and row actions each generate their own
  test.

  Everything is relative and inline: no CDN, no external stylesheet, no
  JavaScript. Open `index.html` from an unzipped artifact and it works offline.
  Traces are linked rather than rendered, because a trace needs Playwright's
  viewer (drag the zip onto <https://trace.playwright.dev>).

  ## Joining media to tests

  The driver names files `Module.test_name_<unix seconds>` with everything
  outside `[a-zA-Z0-9.]` replaced by `_`, and `AshBrowserTests.Reporter` records
  outcomes under the same key. A test with several files — a retry, or two runs
  into the same directory — shows the newest and counts the rest.

  Media with no matching result is still listed, so a run whose formatter was
  not installed produces a usable page.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          screenshots: :string,
          traces: :string,
          results: :string,
          out: :string,
          summary: :string,
          title: :string
        ]
      )

    screenshots = Keyword.get(opts, :screenshots, configured(:screenshot_dir, "screenshots"))
    traces = Keyword.get(opts, :traces, configured(:trace_dir, "traces"))
    out = Keyword.get(opts, :out, common_parent(screenshots, traces))
    title = Keyword.get(opts, :title, "Browser tests")

    results = results(Keyword.get(opts, :results, AshBrowserTests.Reporter.path()))
    rows = rows(results, media(screenshots, ".png"), media(traces, ".zip"))

    File.mkdir_p!(out)
    page = Path.join(out, "index.html")
    File.write!(page, AshBrowserTests.Report.html(rows, title, out))
    Mix.shell().info("report: #{page} (#{length(rows)} tests)")

    case Keyword.get(opts, :summary) || System.get_env("GITHUB_STEP_SUMMARY") do
      nil ->
        :ok

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, AshBrowserTests.Report.markdown(rows, title), [:append])
        Mix.shell().info("summary: #{path}")
    end
  end

  defp configured(key, default) do
    :phoenix_test
    |> Application.get_env(:playwright, [])
    |> Keyword.get(key, default)
  end

  # The page's links are relative, so it has to sit above both directories. For
  # the usual `tmp/playwright/{screenshots,traces}` that is `tmp/playwright`.
  defp common_parent(a, b) do
    shared =
      Path.split(a)
      |> Enum.zip(Path.split(b))
      |> Enum.take_while(fn {x, y} -> x == y end)
      |> Enum.map(&elem(&1, 0))

    case shared do
      [] -> "."
      parts -> Path.join(parts)
    end
  end

  defp results(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"tests" => tests}} <- Jason.decode(body) do
      Map.new(tests, &{&1["key"], &1})
    else
      _absent_or_unreadable -> %{}
    end
  end

  # Newest first, so `hd/1` is the current attempt.
  defp media(dir, extension) do
    dir
    |> Path.join("*" <> extension)
    |> Path.wildcard()
    |> Enum.group_by(&AshBrowserTests.Report.key_of(&1, extension))
    |> Map.new(fn {key, files} -> {key, Enum.sort(files, :desc)} end)
  end

  defp rows(results, shots, traces) do
    results
    |> Map.keys()
    |> Enum.concat(Map.keys(shots))
    |> Enum.concat(Map.keys(traces))
    |> Enum.uniq()
    |> Enum.map(fn key ->
      result = Map.get(results, key, %{})

      %{
        key: key,
        module: Map.get(result, "module"),
        name: Map.get(result, "name"),
        status: Map.get(result, "status", "unknown"),
        time_us: Map.get(result, "time_us"),
        failure: Map.get(result, "failure"),
        journey: journey(Map.get(result, "journey")),
        screenshots: Map.get(shots, key, []),
        traces: Map.get(traces, key, [])
      }
    end)
    |> Enum.sort_by(&AshBrowserTests.Report.order/1)
  end

  defp journey(%{"id" => id, "locale" => locale}), do: %{id: id, locale: locale}
  defp journey(_none), do: nil
end

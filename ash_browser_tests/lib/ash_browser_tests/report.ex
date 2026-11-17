defmodule AshBrowserTests.Report do
  @moduledoc """
  Renders a browser run as one HTML page and one markdown summary.

  Separate from `Mix.Tasks.AshBrowserTests.Report` so the rendering is testable
  without a mix task and a temporary directory per assertion.

  Both outputs are deliberately plain. The page has inline CSS, no JavaScript
  and no external request, so it works from an unzipped artifact on a machine
  with no network. The markdown is for `GITHUB_STEP_SUMMARY`, which renders
  GitHub-flavoured markdown but **cannot show a local image** — only absolute
  URLs — so the summary tells a reader which tests have media and leaves the
  looking to the page.
  """

  @summary_rows 150

  @statuses %{
    "failed" => {0, "✗", "failed"},
    "invalid" => {1, "!", "invalid"},
    "unknown" => {2, "?", "no result"},
    "passed" => {3, "✓", "passed"},
    "skipped" => {4, "–", "skipped"},
    "excluded" => {5, "–", "excluded"}
  }

  @type row :: %{
          required(:key) => String.t(),
          required(:status) => String.t(),
          required(:screenshots) => [String.t()],
          required(:traces) => [String.t()],
          optional(:module) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:time_us) => integer() | nil,
          optional(:failure) => String.t() | nil
        }

  @doc """
  The media key a file belongs to.

  The driver appends `_<unix seconds>` to a screenshot and `_<unix
  seconds>_<unique integer>` to a trace, so how many numeric suffixes to remove
  depends on the extension. Stripping them greedily instead would eat a test
  name that happens to end in a digit — `test_retry_2` is not unusual.
  """
  @spec key_of(String.t(), String.t()) :: String.t()
  def key_of(path, extension) do
    base = Path.basename(path, extension)

    pattern =
      case extension do
        ".zip" -> ~r/^(.*)_\d+_\d+$/
        _one_suffix -> ~r/^(.*)_\d+$/
      end

    case Regex.run(pattern, base) do
      [_whole, key] -> key
      nil -> base
    end
  end

  @doc "Sort key: what failed first, then alphabetical."
  @spec order(row()) :: {integer(), String.t()}
  def order(row), do: {rank(row.status), row.key}

  @doc "The page. `out` is the directory it will be written to, for relative links."
  @spec html([row()], String.t(), String.t()) :: iodata()
  def html(rows, title, out) do
    [
      """
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{escape(title)}</title>
      <style>
      :root { color-scheme: light dark }
      body { font: 15px/1.5 system-ui, sans-serif; margin: 0 auto; max-width: 1100px; padding: 2rem 1rem }
      h1 { font-size: 1.4rem; margin: 0 0 .25rem }
      .counts { color: #666; margin: 0 0 2rem }
      .t { border-top: 1px solid #8884; display: grid; gap: 1rem; grid-template-columns: 340px 1fr;
           padding: 1rem 0 }
      .t img { background: #8881; border-radius: 4px; max-width: 100%; width: 320px }
      .none { color: #999; font-style: italic }
      .name { font-weight: 600; margin: 0 0 .25rem; overflow-wrap: anywhere }
      .mod { color: #666; font-size: .85rem; margin: 0 0 .5rem; overflow-wrap: anywhere }
      .meta { color: #666; font-size: .85rem }
      .failed { color: #c0392b } .passed { color: #1e8449 } .unknown, .skipped, .excluded { color: #888 }
      .invalid { color: #b9770e }
      pre { background: #8881; border-radius: 4px; font-size: .8rem; overflow-x: auto; padding: .75rem }
      a { color: inherit }
      </style></head><body>
      <h1>#{escape(title)}</h1>
      <p class="counts">#{escape(counts(rows))}</p>
      """,
      Enum.map(rows, &row_html(&1, out)),
      "</body></html>\n"
    ]
  end

  @doc "The `GITHUB_STEP_SUMMARY` table."
  @spec markdown([row()], String.t()) :: iodata()
  def markdown(rows, title) do
    {shown, hidden} = Enum.split(rows, @summary_rows)

    [
      "## #{title}\n\n",
      counts(rows),
      "\n\n| | Test | Time | Media |\n|---|---|---|---|\n",
      Enum.map(shown, &markdown_row/1),
      # Never silently truncate: a summary that stops at 150 rows without saying
      # so reads as "that was everything".
      if(hidden == [],
        do: [],
        else: ["\n", "#{length(hidden)} more not shown here — see the report in the artifact.\n"]
      ),
      failures_markdown(rows)
    ]
  end

  defp row_html(row, out) do
    {_rank, mark, label} = status(row.status)
    shot = List.first(row.screenshots)

    [
      ~s(<div class="t"><div>),
      if(shot,
        do: [
          ~s(<a href="#{escape(relative(shot, out))}"><img loading="lazy" alt="" src="),
          escape(relative(shot, out)),
          ~s("></a>)
        ],
        else: ~s(<p class="none">no screenshot</p>)
      ),
      ~s(</div><div>),
      ~s(<p class="name #{escape(row.status)}">#{mark} #{escape(row[:name] || row.key)}</p>),
      if(row[:module], do: ~s(<p class="mod">#{escape(row.module)}</p>), else: []),
      ~s(<p class="meta">#{escape(label)}#{duration(row[:time_us])}),
      trace_links(row.traces, out),
      extras(row),
      ~s(</p>),
      if(row[:failure], do: [~s(<pre>), escape(row.failure), ~s(</pre>)], else: []),
      ~s(</div></div>)
    ]
  end

  defp markdown_row(row) do
    {_rank, mark, _label} = status(row.status)
    media = [media_mark(row.screenshots, "shot"), media_mark(row.traces, "trace")]

    [
      "| ",
      mark,
      " | `",
      escape_pipe(row[:name] || row.key),
      "` | ",
      String.trim_leading(duration(row[:time_us]), " · "),
      " | ",
      media |> Enum.reject(&(&1 == "")) |> Enum.join(", "),
      " |\n"
    ]
  end

  defp failures_markdown(rows) do
    case Enum.filter(rows, &(&1.status in ["failed", "invalid"] and &1[:failure])) do
      [] ->
        []

      failed ->
        [
          "\n<details><summary>Failures</summary>\n\n",
          Enum.map(failed, fn row ->
            ["**", escape_pipe(row[:name] || row.key), "**\n\n```\n", row.failure, "\n```\n\n"]
          end),
          "</details>\n"
        ]
    end
  end

  defp media_mark([], _label), do: ""
  defp media_mark([_one], label), do: label
  defp media_mark(files, label), do: "#{label} ×#{length(files)}"

  defp trace_links([], _out), do: []

  defp trace_links([newest | _older], out) do
    [~s( · <a href="#{escape(relative(newest, out))}">trace</a>)]
  end

  # A second file for one test means a retry, or two runs written to the same
  # directory. Worth saying so rather than quietly showing the newest.
  defp extras(row) do
    case length(row.screenshots) + length(row.traces) do
      n when n > 2 -> " · #{n - 2} earlier attempt(s)"
      _one_each_or_fewer -> []
    end
  end

  defp duration(nil), do: ""
  defp duration(us) when us < 1_000, do: " · #{us}µs"
  defp duration(us) when us < 1_000_000, do: " · #{div(us, 1_000)}ms"
  defp duration(us), do: " · #{Float.round(us / 1_000_000, 1)}s"

  defp counts(rows) do
    rows
    |> Enum.frequencies_by(& &1.status)
    |> Enum.sort_by(fn {status, _n} -> rank(status) end)
    |> Enum.map_join(", ", fn {status, n} ->
      {_rank, _mark, label} = status(status)
      "#{n} #{label}"
    end)
    |> case do
      "" -> "no tests"
      text -> text
    end
  end

  defp status(status), do: Map.get(@statuses, status, {9, "?", status})

  defp rank(status) do
    {rank, _mark, _label} = status(status)
    rank
  end

  defp relative(path, out), do: path |> Path.relative_to(out) |> Path.split() |> Enum.join("/")

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_pipe(value), do: value |> to_string() |> String.replace("|", "\\|")
end

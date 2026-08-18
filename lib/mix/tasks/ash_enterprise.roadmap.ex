defmodule Mix.Tasks.AshEnterprise.Roadmap do
  @shortdoc "Render the enterprise-question and roadmap tables from docs/roadmap.json"

  @moduledoc """
  Renders every status table in the documentation from one machine-readable source.

      mix ash_enterprise.roadmap           # rewrite the marked regions in place
      mix ash_enterprise.roadmap --check   # fail if any region is out of date

  `docs/roadmap.json` is the single source of truth for what this repository
  claims to answer and how far along each answer is. The same data is rendered
  into `README.md`, `docs/QUESTIONS.md`, `docs/ROADMAP.md` and the marketing
  site — so a status can be wrong in one place only by being wrong everywhere,
  which is the point.

  Regions are delimited by HTML comments and rewritten between them:

      <!-- roadmap:questions:start -->
      ...generated...
      <!-- roadmap:questions:end -->

  The available region names are the keys of `renderers/0`. A region naming an
  unknown renderer is an error rather than a silent no-op, because a typo in a
  marker would otherwise present a stale table as a current one.

  `--check` is wired into CI next to `mix ash.codegen --check`. Both exist for
  the same reason: a derived artifact that can drift from its source will.
  """

  use Mix.Task

  @requirements []

  @source "docs/roadmap.json"

  @targets [
    "README.md",
    "docs/QUESTIONS.md",
    "docs/ROADMAP.md"
  ]

  @status_label %{
    "shipped" => "✅ Shipped",
    "partial" => "🟡 Partial",
    "planned" => "🔵 Planned",
    "open" => "⚪ Open"
  }

  @status_order ["shipped", "partial", "planned", "open"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [check: :boolean])
    check? = Keyword.get(opts, :check, false)

    data = load_source!()

    results =
      Enum.map(@targets, fn path ->
        {path, rewrite(path, data)}
      end)

    changed = for {path, {:changed, _}} <- results, do: path

    cond do
      check? and changed != [] ->
        Mix.shell().error("""

        These files are out of date with #{@source}:

        #{Enum.map_join(changed, "\n", &"  * #{&1}")}

        Run `mix ash_enterprise.roadmap` and commit the result.
        """)

        exit({:shutdown, 1})

      check? ->
        Mix.shell().info("Roadmap tables are up to date with #{@source}.")

      true ->
        Enum.each(results, fn
          {path, {:changed, content}} ->
            File.write!(path, content)
            Mix.shell().info("Rewrote #{path}")

          {path, {:unchanged, _}} ->
            Mix.shell().info("Unchanged #{path}")
        end)
    end
  end

  # -- source ---------------------------------------------------------------

  defp load_source! do
    unless File.exists?(@source) do
      Mix.raise("#{@source} does not exist. It is the source of truth for every status table.")
    end

    case @source |> File.read!() |> Jason.decode() do
      {:ok, %{"questions" => questions, "items" => items} = data} ->
        validate!(questions, items)
        data

      {:ok, _} ->
        Mix.raise("#{@source} must contain both a \"questions\" and an \"items\" array.")

      {:error, error} ->
        Mix.raise("#{@source} is not valid JSON: #{Exception.message(error)}")
    end
  end

  # An unknown status would render as a blank cell rather than an error, and a
  # question pointing at a roadmap item that does not exist would render a dead
  # link. Both are the kind of quiet wrongness this file exists to prevent.
  defp validate!(questions, items) do
    item_ids = MapSet.new(items, & &1["id"])

    for entry <- questions ++ items, status = entry["status"] do
      unless Map.has_key?(@status_label, status) do
        Mix.raise(
          "Unknown status #{inspect(status)} on #{inspect(entry["id"])}. " <>
            "Legal statuses: #{Enum.join(@status_order, ", ")}."
        )
      end
    end

    for question <- questions, item = question["item"], not is_nil(item) do
      unless MapSet.member?(item_ids, item) do
        Mix.raise(
          "Question #{inspect(question["id"])} points at roadmap item " <>
            "#{inspect(item)}, which is not defined."
        )
      end
    end

    :ok
  end

  # -- rewriting ------------------------------------------------------------

  defp rewrite(path, data) do
    unless File.exists?(path) do
      Mix.raise("#{path} does not exist.")
    end

    original = File.read!(path)

    # Matches an empty region too -- the first render happens against markers with
    # nothing between them, and a pattern requiring a newline on each side of the
    # body silently leaves those alone.
    rendered =
      Regex.replace(
        ~r/<!-- roadmap:([a-z0-9-]+):start -->.*?<!-- roadmap:\1:end -->/s,
        original,
        fn _whole, name ->
          "<!-- roadmap:#{name}:start -->\n" <>
            render!(name, data, path) <> "\n<!-- roadmap:#{name}:end -->"
        end
      )

    if rendered == original, do: {:unchanged, rendered}, else: {:changed, rendered}
  end

  defp render!(name, data, path) do
    case renderers()[name] do
      nil ->
        Mix.raise(
          "#{path} contains a <!-- roadmap:#{name} --> region, but there is no " <>
            "renderer by that name. Known renderers: #{renderers() |> Map.keys() |> Enum.sort() |> Enum.join(", ")}."
        )

      fun ->
        # Every rendered link is relative to the file it lands in, so the same
        # ADR reference resolves from README.md and from docs/ROADMAP.md alike.
        fun.(Map.put(data, :__base__, Path.dirname(path)))
    end
  end

  defp renderers do
    %{
      "questions" => &questions_table/1,
      "questions-summary" => &questions_summary/1,
      "items" => &items_table/1,
      "scoreboard" => &scoreboard/1
    }
  end

  # -- renderers ------------------------------------------------------------

  # The full checklist, grouped by section, with the proof column that makes a
  # "shipped" claim checkable rather than asserted.
  defp questions_table(%{"questions" => questions} = data) do
    base = base(data)

    questions
    |> Enum.group_by(& &1["section"])
    |> Enum.sort_by(fn {section, _} -> section_order(data, section) end)
    |> Enum.map_join("\n\n", fn {section, rows} ->
      """
      ### #{section_title(data, section)}

      | # | Question | Our answer | Status | Proven by |
      |---|---|---|---|---|
      """ <>
        Enum.map_join(rows, "\n", fn q ->
          "| #{number(q)} | #{q["question"]} | #{q["answer"]} | #{status(q)} | #{proof(q, base)} |"
        end)
    end)
  end

  # The condensed form for the README: no proof column, no section headings.
  defp questions_summary(%{"questions" => questions} = data) do
    """
    | # | Question | Our answer | Status |
    |---|---|---|---|
    """ <>
      (questions
       |> Enum.sort_by(&{section_order(data, &1["section"]), number(&1)})
       |> Enum.map_join("\n", fn q ->
         "| #{number(q)} | #{q["question"]} | #{q["answer"]} | #{status(q)} |"
       end))
  end

  defp items_table(%{"items" => items} = data) do
    base = base(data)

    """
    | Priority | Gap | Choice | Status | ADR |
    |---|---|---|---|---|
    """ <>
      (items
       |> Enum.sort_by(&{&1["priority"], &1["title"]})
       |> Enum.map_join("\n", fn item ->
         "| #{item["priority"]} | #{item["title"]} | #{item["choice"]} | " <>
           "#{@status_label[item["status"]]} | #{adr_link(item["adr"], base)} |"
       end))
  end

  # The counter the landing page leads with. Deliberately counts only "shipped"
  # as answered -- "partial" is not an answer, it is a caveat.
  defp scoreboard(%{"questions" => questions}) do
    counts = Enum.frequencies_by(questions, & &1["status"])
    total = length(questions)
    shipped = Map.get(counts, "shipped", 0)

    tally =
      Enum.map_join(@status_order, " · ", fn status ->
        "#{@status_label[status]} #{Map.get(counts, status, 0)}"
      end)

    "**#{shipped} of #{total}** enterprise questions have a shipped answer.\n\n#{tally}"
  end

  # -- cells ----------------------------------------------------------------

  defp number(%{"id" => "q" <> n}), do: n
  defp number(%{"id" => id}), do: id

  defp status(%{"status" => status}), do: @status_label[status]

  # A shipped claim points at code or a test; a planned one points at the ADR or
  # plan that reasons about it. Nothing points at nothing without saying so.
  defp proof(entry, base) do
    cond do
      is_binary(entry["proof"]) -> "`#{entry["proof"]}`"
      is_binary(entry["adr"]) -> adr_link(entry["adr"], base)
      is_binary(entry["plan"]) -> "[plan](#{relative(base, entry["plan"])})"
      true -> "—"
    end
  end

  defp adr_link(nil, _base), do: "—"

  defp adr_link(adr, base),
    do: "[ADR #{adr}](#{relative(base, "docs/adr/#{adr_slug(adr)}")})"

  # Paths in roadmap.json are repo-relative; links have to be relative to the
  # file being written, or they resolve from README.md and break from docs/.
  defp relative(".", path), do: path
  defp relative(base, path), do: Path.relative_to(path, base)

  # The index in docs/adr/README.md is authoritative for slugs; resolve against
  # the directory so a renamed ADR surfaces here rather than as a dead link.
  defp adr_slug(adr) do
    case Path.wildcard("docs/adr/#{adr}-*.md") do
      [path | _] -> Path.basename(path)
      [] -> Mix.raise("No ADR file found for number #{adr} in docs/adr/.")
    end
  end

  defp base(%{__base__: base}), do: base
  defp base(_), do: "."

  defp sections(%{"sections" => sections}), do: sections
  defp sections(_), do: []

  defp section_order(data, id) do
    data |> sections() |> Enum.find_index(&(&1["id"] == id)) || 999
  end

  defp section_title(data, id) do
    case data |> sections() |> Enum.find(&(&1["id"] == id)) do
      %{"title" => title} -> title
      _ -> id
    end
  end
end

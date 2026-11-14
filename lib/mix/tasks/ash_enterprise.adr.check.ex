defmodule Mix.Tasks.AshEnterprise.Adr.Check do
  @shortdoc "Fail if the ADR set disagrees with itself (status, index, cross-references)"

  @moduledoc """
  Checks that `docs/adr/` agrees with itself.

      mix ash_enterprise.adr.check

  A status that can drift from the record it summarises will, and an index that
  silently disagrees with the ADR it points at is worse than no index. This is the
  same reasoning as `mix ash_enterprise.roadmap --check` and `mix ash.codegen --check`,
  and it runs next to them in CI. It reads files only and changes nothing.

  What it enforces:

    * every `NNNN-slug.md` has a unique number, with no gaps in the sequence
      (numbers are never reused or renumbered);
    * the first line is `# ADR NNNN — Title` with the file's own number;
    * the file carries `- **Status:**` and `- **Date:**` lines, and the status
      starts with one of `proposed`, `accepted`, `rejected`, `superseded`;
    * a `superseded by ADR NNNN` status names an ADR that exists;
    * `README.md` has exactly one index row per ADR, linking the real filename,
      and the row's status begins with the same word as the ADR's own;
    * every relative `.md` link, and every `ADR NNNN` mention, resolves.

  Only the first word of a status is compared with the index: the detail after it
  ("built (2026-11-12)", "not built") is prose each record owns, and the index
  abbreviates it.
  """

  use Mix.Task

  @requirements []

  @dir "docs/adr"
  @families ~w(proposed accepted rejected superseded)

  @impl Mix.Task
  def run(_args) do
    files =
      @dir
      |> Path.join("[0-9][0-9][0-9][0-9]-*.md")
      |> Path.wildcard()
      |> Enum.sort()

    adrs = Map.new(files, &parse/1)
    numbers = adrs |> Map.keys() |> Enum.sort()
    index = index_rows()

    errors =
      Enum.concat([
        sequence_errors(files, numbers),
        Enum.flat_map(adrs, fn {_n, adr} -> adr_errors(adr, adrs) end),
        index_errors(adrs, index),
        link_errors(files ++ [Path.join(@dir, "README.md")], adrs)
      ])

    case errors do
      [] ->
        Mix.shell().info("ADR set consistent: #{length(files)} records.")

      errors ->
        Enum.each(errors, fn e -> Mix.shell().error(e) end)
        Mix.raise("#{length(errors)} ADR consistency problem(s); see above.")
    end
  end

  defp parse(file) do
    text = File.read!(file)
    [number | _] = file |> Path.basename() |> String.split("-", parts: 2)

    {number,
     %{
       file: file,
       number: number,
       text: text,
       heading: text |> String.split("\n", parts: 2) |> hd(),
       status: field(text, "Status"),
       date: field(text, "Date")
     }}
  end

  defp field(text, name) do
    case Regex.run(~r/^- \*\*#{name}:\*\*\s*(.+)$/m, text) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp family(nil), do: nil

  defp family(status) do
    case Regex.run(~r/^(\w+)/, String.downcase(status)) do
      [_, word] -> word
      nil -> nil
    end
  end

  defp sequence_errors(files, numbers) do
    dupes = (files |> Enum.map(&(&1 |> Path.basename() |> binary_part(0, 4)))) -- numbers

    expected = Enum.map(1..max(length(numbers), 1), &pad/1)

    Enum.map(dupes, &"#{@dir}: number #{&1} is used by more than one file") ++
      Enum.map(
        expected -- numbers,
        &"#{@dir}: ADR #{&1} is missing; numbers are never reused or removed"
      )
  end

  defp adr_errors(adr, adrs) do
    heading_ok? = String.starts_with?(adr.heading, "# ADR #{adr.number} —")

    [
      {not heading_ok?, "#{adr.file}: first line must start `# ADR #{adr.number} — `"},
      {is_nil(adr.status), "#{adr.file}: no `- **Status:**` line"},
      {is_nil(adr.date), "#{adr.file}: no `- **Date:**` line"},
      {adr.status && family(adr.status) not in @families,
       "#{adr.file}: status must start with one of #{Enum.join(@families, ", ")}, got: #{adr.status}"},
      {superseded_target_missing?(adr, adrs),
       "#{adr.file}: `superseded by` names an ADR that does not exist"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp superseded_target_missing?(%{status: nil}, _), do: false

  defp superseded_target_missing?(%{status: status}, adrs) do
    case Regex.run(~r/superseded by \[?ADR[ -](\d{4})/i, status) do
      [_, target] -> not Map.has_key?(adrs, target)
      nil -> family(status) == "superseded"
    end
  end

  defp index_rows do
    @dir
    |> Path.join("README.md")
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\| \[(\d{4})\]\(([^)]+)\) \|.*\| ([^|]+) \|$/, line) do
        [_, number, link, status] -> [{number, link, String.trim(status)}]
        nil -> []
      end
    end)
  end

  defp index_errors(adrs, index) do
    by_number = Enum.group_by(index, &elem(&1, 0))

    Enum.flat_map(adrs, fn {number, adr} ->
      case Map.get(by_number, number, []) do
        [] ->
          ["#{@dir}/README.md: no index row for ADR #{number}"]

        [{_, link, status}] ->
          [
            {link != Path.basename(adr.file),
             "#{@dir}/README.md: ADR #{number} row links #{link}, expected #{Path.basename(adr.file)}"},
            {family(status) != family(adr.status),
             "#{@dir}/README.md: ADR #{number} index status is `#{family(status)}`, but #{adr.file} says `#{family(adr.status)}`"}
          ]
          |> Enum.filter(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        _many ->
          ["#{@dir}/README.md: more than one index row for ADR #{number}"]
      end
    end) ++
      for {number, _, _} <- index, not Map.has_key?(adrs, number) do
        "#{@dir}/README.md: index row for ADR #{number}, which has no file"
      end
  end

  defp link_errors(files, adrs) do
    Enum.flat_map(files, fn file ->
      text = File.read!(file)

      links =
        for [_, target] <- Regex.scan(~r/\]\(([^)#\s]+\.md)(?:#[^)]*)?\)/, text),
            not String.starts_with?(target, ["http://", "https://"]),
            not File.exists?(Path.join(Path.dirname(file), target)) do
          "#{file}: link to #{target} does not resolve"
        end

      mentions =
        for [_, number] <- Regex.scan(~r/\bADRs? (\d{4})\b/, text),
            not Map.has_key?(adrs, number) do
          "#{file}: mentions ADR #{number}, which does not exist"
        end

      links ++ Enum.uniq(mentions)
    end)
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")
end

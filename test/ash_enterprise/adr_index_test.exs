defmodule AshEnterprise.AdrIndexTest do
  @moduledoc """
  Keeps docs/adr/README.md and the records in docs/adr/ in step. The index is
  where a reader learns what was decided and whether it is built, so a record
  missing from it, a row pointing at no file, or a row with no status is a
  decision nobody can find.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @adr_dir Path.join(@root, "docs/adr")
  @index_path Path.join(@adr_dir, "README.md")

  # Rows look like: | [0055](0055-some-title.md) | Title | status |
  @row ~r/^\| \[(\d{4})\]\(([^)]+)\) \| (.+?) \| (.*?) \|\s*$/m

  setup_all do
    files =
      @adr_dir
      |> File.ls!()
      |> Enum.filter(&Regex.match?(~r/^\d{4}-.+\.md$/, &1))
      |> Map.new(&{String.slice(&1, 0, 4), &1})

    rows =
      @row
      |> Regex.scan(File.read!(@index_path), capture: :all_but_first)
      |> Enum.map(fn [number, link, title, status] ->
        %{number: number, link: link, title: String.trim(title), status: String.trim(status)}
      end)

    %{files: files, rows: rows}
  end

  test "every record has exactly one index row, linking to its own file", %{
    files: files,
    rows: rows
  } do
    by_number = Enum.group_by(rows, & &1.number)

    problems =
      files
      |> Enum.map(fn {number, file} ->
        row_problem(number, file, Map.get(by_number, number, []))
      end)
      |> Enum.reject(&is_nil/1)

    assert problems == [], "docs/adr/README.md is out of step:\n" <> Enum.join(problems, "\n")
  end

  defp row_problem(_number, file, [%{link: file}]), do: nil
  defp row_problem(number, _file, []), do: "#{number}: no index row"

  defp row_problem(number, file, [%{link: link}]),
    do: "#{number}: the row links #{link}, the file is #{file}"

  defp row_problem(number, _file, many), do: "#{number}: #{length(many)} index rows"

  test "every index row points at a record that exists", %{files: files, rows: rows} do
    dangling =
      for %{number: number, link: link} <- rows,
          Map.get(files, number) != link,
          do: "#{number} -> #{link}"

    assert dangling == [], "index rows with no record: #{Enum.join(dangling, ", ")}"
  end

  test "every index row has a title and a status", %{rows: rows} do
    incomplete = for row <- rows, row.title == "" or row.status == "", do: row.number

    assert incomplete == [],
           "index rows missing a title or status: #{Enum.join(incomplete, ", ")}"
  end

  test "each record's heading names its own number", %{files: files} do
    mismatched =
      for {number, file} <- files,
          heading = @adr_dir |> Path.join(file) |> File.stream!() |> Enum.at(0),
          not String.contains?(heading, "ADR #{number}"),
          do: file

    assert mismatched == [],
           "records whose first line does not name them: #{Enum.join(mismatched, ", ")}"
  end

  test "the agent runtime records 0055-0058 are written and indexed with a status", %{
    files: files,
    rows: rows
  } do
    for number <- ~w(0055 0056 0057 0058) do
      assert Map.has_key?(files, number), "docs/adr/#{number}-*.md is missing"

      assert %{status: status} = Enum.find(rows, &(&1.number == number)),
             "ADR #{number} has no row in docs/adr/README.md"

      assert status =~ ~r/^(proposed|accepted|superseded)/,
             "ADR #{number}'s status #{inspect(status)} is not one the index format allows"
    end
  end
end

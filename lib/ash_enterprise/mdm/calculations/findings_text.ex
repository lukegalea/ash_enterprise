defmodule AshEnterprise.Mdm.Calculations.FindingsText do
  @moduledoc """
  A staged row's validation findings as text, one per line, or nil when the
  row mapped cleanly. Reads only the row's own `validation_findings`.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:validation_findings]

  @impl true
  def calculate(records, _opts, _context) do
    {:ok, Enum.map(records, &text(&1.validation_findings))}
  end

  defp text(findings) when is_map(findings) do
    findings
    |> Enum.flat_map(fn {_kind, items} -> List.wrap(items) end)
    |> Enum.map(&line/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp text(_findings), do: nil

  defp line(finding) when is_map(finding) do
    text = finding["message"] || finding["reason"] || inspect(finding)

    case finding["path"] || finding["target"] do
      nil -> to_string(text)
      path -> "#{path}: #{text}"
    end
  end

  defp line(other) when is_binary(other), do: other
  defp line(other), do: inspect(other)
end

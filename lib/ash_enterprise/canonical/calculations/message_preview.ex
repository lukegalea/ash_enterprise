defmodule AshEnterprise.Canonical.Calculations.MessagePreview do
  @moduledoc """
  A message's body on one line, clipped to 280 characters — for a row in a
  related table (a thread's messages, a person's sent mail). Whitespace runs
  collapse to one space. A shredded body reads `[shredded]`.
  """

  use Ash.Resource.Calculation

  @max 280

  @impl true
  def load(_query, _opts, _context), do: [:body]

  @impl true
  def calculate(messages, _opts, _context), do: {:ok, Enum.map(messages, &preview(&1.body))}

  defp preview(nil), do: nil

  defp preview(body) do
    line = body |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(line) > @max, do: String.slice(line, 0, @max) <> "…", else: line
  end
end

defmodule AshEnterprise.Canonical.Calculations.LatestMessage do
  @moduledoc """
  A conversation's newest message in one line, for a list row:
  `Alice Chen: Can you look at the award flow before…` — sender, then the
  start of the body (#{140} characters). Loaded through `messages` under the
  reading actor's policies; a shredded body reads `[shredded]`.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Canonical.Message

  @max 140

  @impl true
  def load(_query, _opts, _context) do
    latest =
      Message
      |> Ash.Query.sort(sent_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.ensure_selected([:sent_at, :direction])
      |> Ash.Query.load([:body, :sender_label])

    [messages: latest]
  end

  @impl true
  def calculate(conversations, _opts, _context) do
    {:ok, Enum.map(conversations, &line(List.first(&1.messages || [])))}
  end

  defp line(nil), do: nil

  defp line(message) do
    who =
      message.sender_label || if(message.direction == :outbound, do: "Me", else: "Unknown")

    body = message.body |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    body = if String.length(body) > @max, do: String.slice(body, 0, @max) <> "…", else: body
    "#{who}: #{body}"
  end
end

defmodule AshEnterprise.Canonical.Calculations.LatestMessage do
  @moduledoc """
  A conversation's newest message in one line, for a list row:
  `Alice Chen: Can you look at the award flow before…` — sender, then the
  start of the body (#{140} characters); a shredded body reads `[shredded]`.

  `messages` is loaded in `calculate/3` **as the reader**, under their
  policies: a relationship named in `load/3` would be loaded as a
  calculation dependency, which Ash does without authorization (see
  `AshEnterprise.Platform.Calculations.RelatedField`), and the sender label
  nested inside it would then load unauthorized too. A message the reader
  may not read is not their latest message; a sender they may not read is
  unnamed.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Canonical.Message
  alias AshEnterprise.Platform.Calculations.RelatedField

  @max 140

  # Only the conversation's own key: the messages are loaded as the reader below.
  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(conversations, _opts, context) do
    latest =
      Message
      |> Ash.Query.sort(sent_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.ensure_selected([:sent_at, :direction])
      |> Ash.Query.load([:body, :sender_label])

    with {:ok, loaded} <- RelatedField.load_related(conversations, :messages, latest, context) do
      {:ok, Enum.map(loaded, &line(List.first(&1.messages || [])))}
    end
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

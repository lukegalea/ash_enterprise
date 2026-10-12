defmodule AshEnterprise.Canonical.Calculations.ConversationMessages do
  @moduledoc """
  A conversation's latest messages as Markdown for its detail pane: who, when
  (the operator's wall clock), which way, and the body — newest last, at most
  #{20}. Loaded through `messages` under the reading actor's policies; a
  shredded body reads `[shredded]`.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Canonical.Message
  alias AshEnterprise.Platform.LocalTime

  @limit 20

  @impl true
  def load(_query, _opts, _context) do
    messages =
      Message
      |> Ash.Query.sort(sent_at: :desc)
      |> Ash.Query.limit(@limit)
      |> Ash.Query.ensure_selected([:sent_at, :direction])
      |> Ash.Query.load([:body, :sender_label])

    [messages: messages]
  end

  @impl true
  def calculate(conversations, _opts, _context) do
    {:ok, Enum.map(conversations, &render(&1.messages))}
  end

  @doc false
  def render(messages) when messages in [nil, []], do: "No messages."

  def render(messages) do
    messages
    |> Enum.sort_by(& &1.sent_at, DateTime)
    |> Enum.map_join("\n\n", fn message ->
      who = message.sender_label || if(message.direction == :outbound, do: "Me", else: "Unknown")
      arrow = if message.direction == :outbound, do: "→", else: "←"
      "**#{who}** #{arrow} #{LocalTime.stamp(message.sent_at)}\n\n#{message.body}"
    end)
  end
end

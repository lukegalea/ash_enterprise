defmodule AshEnterprise.Assistant.Lookups.Messages do
  @moduledoc """
  `Lookup.Message.read_messages`: the messages themselves, newest first — in one
  conversation (by its ref) or across all of them by sender, text and
  window (default `last_30_days`; any time within one conversation).

  `Message.read` as the person: owner-only and zone-admitted rows only
  (ADR 0042), bodies decrypted by that read for their owner (ADR 0024) and
  by nothing here. Each message is cited by its conversation's ref, since a
  message opens on its thread's surface. At most #{1000} messages are
  scanned and #{20} returned, each body clipped to #{600} characters.
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.{Conversations, Support}
  alias AshEnterprise.Canonical.{Conversation, Message}

  @scan 1000
  @shown 20
  @body 600

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      args = query.arguments

      with {:ok, conversation_id} <- conversation_id(args[:conversation]),
           {:ok, bounds} <- bounds(args[:window], conversation_id),
           {:ok, messages} <- scan(conversation_id, args[:person], bounds, opts) do
        {:ok,
         messages
         |> Enum.filter(&Support.matches?(Support.text(&1.body), args[:text]))
         |> Enum.take(@shown)
         |> Enum.map(&row/1)}
      end
    end)
  end

  # A ref (`inbox:<id>`, `slack:<id>`) or a bare id; anything else is the
  # model's mistake, said plainly so it can correct it.
  defp conversation_id(value) when value in [nil, ""], do: {:ok, nil}

  defp conversation_id(value) do
    id = value |> String.trim() |> String.split(":") |> List.last()

    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         "#{inspect(value)} is not a conversation ref. Pass the ref find_conversations returned."}
    end
  end

  defp bounds(window, conversation_id) do
    case {Support.window(window), conversation_id} do
      {:none, nil} -> Support.window("last_30_days")
      {:none, _one_conversation} -> {:ok, nil}
      {other, _} -> other
    end
  end

  defp scan(conversation_id, person, bounds, opts) do
    Message
    |> Ash.Query.for_read(:read, %{}, opts)
    |> in_conversation(conversation_id)
    |> from_person(person)
    |> in_window(bounds)
    |> Ash.Query.sort(sent_at: :desc)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([:sent, :sender_label, conversation: [:subject]])
    |> Ash.read(opts)
  end

  defp in_conversation(query, nil), do: query
  defp in_conversation(query, id), do: Ash.Query.filter(query, conversation_id == ^id)

  defp from_person(query, person) when person in [nil, ""], do: query

  defp from_person(query, person) do
    pattern = Support.like(person)

    Ash.Query.filter(
      query,
      ilike(sender.name, ^pattern) or ilike(type(sender.email, :string), ^pattern)
    )
  end

  defp in_window(query, nil), do: query

  defp in_window(query, {from, to}),
    do: Ash.Query.filter(query, sent_at >= ^from and sent_at < ^to)

  defp row(message) do
    conversation = loaded(message.conversation)

    Support.row(Lookup.Message, %{
      ref: conversation && Support.ref(Conversation, conversation),
      conversation: conversation && Support.clip(conversation.subject, 120),
      from: Conversations.from(message),
      sent: message.sent,
      text: Support.clip(message.body, @body)
    })
  end

  defp loaded(%Conversation{} = conversation), do: conversation
  defp loaded(_none), do: nil
end

defmodule AshEnterprise.Assistant.Lookups.Conversations do
  @moduledoc """
  `Lookup.Conversation.find_conversations`: the person's Gmail threads and Slack
  conversations, newest activity first.

  Everything is read as the person through the canonical read actions
  (`Conversation.read` / `:gmail` / `:slack`, `Message.read`), so only
  their own, zone-admitted rows exist here at all (owner-only, ADR 0042):
  content the zone gate refused at projection was never written, and
  another person's mail is filtered out by the read, not by this module.

  * **person** — a participant (the derived `people` joins) or a sender,
    matched in SQL on the person's name and address (plaintext columns).
  * **window** — the thread had a message sent in it.
  * **text** — subject and message bodies are sealed, so they are matched
    after the read, on decrypted values: up to #{300} threads and #{2000}
    messages are scanned.
  * **needs_reply** — the thread's latest message is inbound (someone
    else's), read from each thread's newest message.
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.{Conversation, Message}

  @scan 300
  @message_scan 2000
  @shown 25

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, &lookup(query.arguments, &1))
  end

  defp lookup(args, opts) do
    with {:ok, bounds} <- optional_window(args[:window]),
         {:ok, threads} <- read(args, bounds, opts),
         {:ok, threads} <- by_text(threads, args[:text], bounds, opts) do
      {:ok,
       threads
       |> awaiting_reply(args[:needs_reply])
       |> Enum.take(@shown)
       |> Enum.map(&row/1)}
    end
  end

  defp awaiting_reply(threads, true), do: Enum.filter(threads, &needs_reply?/1)
  defp awaiting_reply(threads, _any), do: threads

  defp optional_window(window) do
    case Support.window(window) do
      :none -> {:ok, nil}
      other -> other
    end
  end

  defp read(args, bounds, opts) do
    Conversation
    |> Ash.Query.for_read(action(args[:source]), %{}, opts)
    |> Ash.Query.sort(last_message_at: :desc_nils_last)
    |> by_person(args[:person])
    |> in_window(bounds)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([
      :message_count,
      :last_message_at,
      :last_activity,
      :kind_label,
      messages:
        Message
        |> Ash.Query.sort(sent_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.load([:sender_label])
    ])
    |> Ash.read(opts)
  end

  defp action(:gmail), do: :gmail
  defp action(:slack), do: :slack
  defp action(_any), do: :read

  defp by_person(query, person) when person in [nil, ""], do: query

  defp by_person(query, person) do
    pattern = Support.like(person)

    Ash.Query.filter(
      query,
      exists(people, ilike(name, ^pattern) or ilike(type(email, :string), ^pattern)) or
        exists(
          messages.sender,
          ilike(name, ^pattern) or ilike(type(email, :string), ^pattern)
        )
    )
  end

  defp in_window(query, nil), do: query

  defp in_window(query, {from, to}),
    do: Ash.Query.filter(query, exists(messages, sent_at >= ^from and sent_at < ^to))

  defp by_text(threads, text, _bounds, _opts) when text in [nil, ""], do: {:ok, threads}

  defp by_text(threads, text, bounds, opts) do
    ids = Enum.map(threads, & &1.id)

    with {:ok, hits} <- body_hits(ids, text, bounds, opts) do
      {:ok,
       Enum.filter(threads, fn thread ->
         Support.matches?(Support.text(thread.subject), text) or MapSet.member?(hits, thread.id)
       end)}
    end
  end

  # The threads (among `ids`) holding a message whose decrypted body matches.
  defp body_hits([], _text, _bounds, _opts), do: {:ok, MapSet.new()}

  defp body_hits(ids, text, bounds, opts) do
    Message
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(conversation_id in ^ids)
    |> sent_in(bounds)
    |> Ash.Query.sort(sent_at: :desc)
    |> Ash.Query.limit(@message_scan)
    |> Ash.read(opts)
    |> case do
      {:ok, messages} ->
        {:ok,
         messages
         |> Enum.filter(&Support.matches?(Support.text(&1.body), text))
         |> MapSet.new(& &1.conversation_id)}

      error ->
        error
    end
  end

  defp sent_in(query, nil), do: query
  defp sent_in(query, {from, to}), do: Ash.Query.filter(query, sent_at >= ^from and sent_at < ^to)

  defp latest(%{messages: [message | _]}), do: message
  defp latest(_thread), do: nil

  defp needs_reply?(thread), do: match?(%{direction: :inbound}, latest(thread))

  defp row(thread) do
    last = latest(thread)

    Support.row(Lookup.Conversation, %{
      ref: Support.ref(Conversation, thread),
      source: thread.external_system,
      kind: thread.kind_label,
      subject: Support.clip(thread.subject, 160),
      last_activity: thread.last_activity,
      messages: thread.message_count,
      last_from: last && from(last),
      last_preview: last && Support.clip(last.body, 140),
      needs_reply: needs_reply?(thread)
    })
  end

  @doc false
  def from(%{direction: :outbound}), do: "me"
  def from(message), do: Support.text(message.sender_label) || "unknown sender"
end

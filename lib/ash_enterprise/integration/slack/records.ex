defmodule AshEnterprise.Integration.Slack.Records do
  @moduledoc """
  Slack payloads → `AshEnterprise.Integration.SourceRecord`s, and the Slack
  `ts` arithmetic the sync cursor needs. Pure: no I/O, no clock (the fetch time
  is passed in).

  ## External ids

  `SourceObject` identity is `[external_system, external_id]` *without* the
  stream (the known E1 gap), and a Slack `ts` is only unique inside one
  conversation, so every id is fully qualified — and qualified by the **linked
  account** it was fetched through:

  | Stream | `external_id` |
  |---|---|
  | `slack.conversations` | `<linked_account_id>/conversation/<channel_id>` |
  | `slack.messages` | `<linked_account_id>/message/<channel_id>/<ts>` |
  | `slack.users` | `<linked_account_id>/user/<user_id>` |

  The linked-account prefix keeps every row inside exactly one shred scope: two
  linked accounts that can both see a message land two rows, each under its own
  scope, so erasing one account (destroying its key, ADR 0024) never touches a
  row the other still needs, and never leaves a row behind.

  `source_metadata` carries only identifiers (`stream`, `linked_account_id`,
  `channel_id`) — never content — because it is bookkeeping, and lineage and
  logs may see bookkeeping.
  """

  alias AshEnterprise.Integration.SourceRecord

  @external_system "slack"

  @streams %{
    conversations: "slack.conversations",
    messages: "slack.messages",
    users: "slack.users"
  }

  @ts ~r/\A\d{1,12}\.\d{6}\z/

  @doc "The `external_system` every Slack record lands under."
  def external_system, do: @external_system

  @doc "The stream name for `:conversations`, `:messages` or `:users`."
  def stream(kind), do: Map.fetch!(@streams, kind)

  @doc "A conversation (`users.conversations` item)."
  @spec conversation(String.t(), map(), DateTime.t()) :: SourceRecord.t()
  def conversation(linked_account_id, %{"id" => channel_id} = payload, fetched_at) do
    %SourceRecord{
      external_system: @external_system,
      external_id: conversation_id(linked_account_id, channel_id),
      stream: stream(:conversations),
      raw_payload: payload,
      cursor: nil,
      fetched_at: fetched_at,
      source_metadata: metadata(:conversations, linked_account_id, channel_id)
    }
  end

  @doc """
  A message (`conversations.history` item). The channel is not in a history
  item, so it is passed in; `cursor` is the conversation's pass position the
  message was fetched under (`%{"oldest" => ts}`).
  """
  @spec message(String.t(), String.t(), map(), map() | nil, DateTime.t()) :: SourceRecord.t()
  def message(linked_account_id, channel_id, %{"ts" => ts} = payload, cursor, fetched_at) do
    %SourceRecord{
      external_system: @external_system,
      external_id: message_id(linked_account_id, channel_id, ts),
      stream: stream(:messages),
      raw_payload: payload,
      cursor: cursor,
      fetched_at: fetched_at,
      source_metadata: metadata(:messages, linked_account_id, channel_id)
    }
  end

  @doc "A workspace member (`users.info` `user` object)."
  @spec user(String.t(), map(), DateTime.t()) :: SourceRecord.t()
  def user(linked_account_id, %{"id" => user_id} = payload, fetched_at) do
    %SourceRecord{
      external_system: @external_system,
      external_id: user_id(linked_account_id, user_id),
      stream: stream(:users),
      raw_payload: payload,
      cursor: nil,
      fetched_at: fetched_at,
      source_metadata: %{"stream" => stream(:users), "linked_account_id" => linked_account_id}
    }
  end

  @doc false
  def conversation_id(la, channel), do: "#{la}/conversation/#{channel}"
  @doc false
  def message_id(la, channel, ts), do: "#{la}/message/#{channel}/#{ts}"
  @doc false
  def user_id(la, user), do: "#{la}/user/#{user}"

  defp metadata(kind, linked_account_id, channel_id) do
    %{
      "stream" => stream(kind),
      "linked_account_id" => linked_account_id,
      "channel_id" => channel_id
    }
  end

  @doc """
  The Slack user ids a set of messages (and, for an IM, the conversation)
  refer to as authors. Bot messages without a `user` are skipped.
  """
  @spec author_ids([map()]) :: [String.t()]
  def author_ids(messages) do
    messages
    |> Enum.flat_map(fn
      %{"user" => user} when is_binary(user) and user != "" -> [user]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # --- ts arithmetic --------------------------------------------------------------

  @doc "Whether `value` is a Slack `ts` (`\"1712345678.000100\"`)."
  @spec ts?(term()) :: boolean()
  def ts?(value) when is_binary(value), do: Regex.match?(@ts, value)
  def ts?(_), do: false

  @doc "A `ts` as integer microseconds since the epoch."
  @spec ts_to_micro(String.t()) :: non_neg_integer()
  def ts_to_micro(ts) do
    [seconds, fraction] = String.split(ts, ".")
    String.to_integer(seconds) * 1_000_000 + String.to_integer(fraction)
  end

  @doc "A `ts` as a `DateTime` (microsecond precision)."
  @spec ts_to_datetime(String.t()) :: DateTime.t()
  def ts_to_datetime(ts), do: DateTime.from_unix!(ts_to_micro(ts), :microsecond)

  @doc "The `ts` for a `DateTime`."
  @spec datetime_to_ts(DateTime.t()) :: String.t()
  def datetime_to_ts(%DateTime{} = datetime) do
    micro = DateTime.to_unix(datetime, :microsecond)
    seconds = div(micro, 1_000_000)
    fraction = rem(micro, 1_000_000)
    "#{seconds}." <> String.pad_leading(Integer.to_string(fraction), 6, "0")
  end

  @doc "The later of two `ts` values; `nil` is earlier than anything."
  @spec max_ts(String.t() | nil, String.t() | nil) :: String.t() | nil
  def max_ts(nil, b), do: b
  def max_ts(a, nil), do: a
  def max_ts(a, b), do: if(ts_to_micro(a) >= ts_to_micro(b), do: a, else: b)
end

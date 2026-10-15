defmodule AshEnterprise.Canonical.Actions.InboxDigest do
  @moduledoc """
  `Conversation.inbox_digest`: one message vertical's conversations as plain
  text, for a terminal transcript (the ACP `inbox` / `slack` prompts). Reads
  the vertical's read action as the calling actor; while the zone gate holds
  the vertical back (`AshEnterprise.Canonical.Admission`), an empty inbox says
  so rather than "no messages".
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Canonical.{Admission, Conversation}
  alias AshEnterprise.Platform.LocalTime

  @max 25

  @impl true
  def run(input, _opts, context) do
    system = input.arguments[:system] || :gmail
    opts = Ash.Context.to_opts(context)

    Conversation
    |> Ash.Query.for_read(system, %{}, opts)
    |> Ash.Query.load([:subject, :message_count, :last_message_at, :kind_label])
    |> Ash.read(opts)
    |> case do
      {:ok, conversations} -> {:ok, render(system, conversations, linked?(system, opts))}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def render(system, [], linked?) do
    "#{title(system)} — no conversations.\n" <> Admission.empty_message(system, linked?)
  end

  def render(system, conversations, _linked?) do
    lines =
      conversations
      |> Enum.take(@max)
      |> group(system)
      |> Enum.flat_map(fn {heading, rows} ->
        heading_line = if heading, do: ["#{heading}"], else: []

        heading_line ++
          Enum.map(rows, fn conversation ->
            "  #{LocalTime.stamp(conversation.last_message_at)}  " <>
              "#{conversation.subject || "(no subject)"}  · #{count(conversation.message_count)}"
          end)
      end)

    more =
      if length(conversations) > @max,
        do: ["  … and #{length(conversations) - @max} more"],
        else: []

    Enum.join(["#{title(system)} — #{length(conversations)} conversations" | lines ++ more], "\n")
  end

  # Whether the actor has an active linked account for the vertical (their
  # own, under their policies) — only consulted to explain an empty inbox.
  defp linked?(system, opts) do
    case AshEnterprise.Integration.LinkedAccount.for_operation(
           Admission.integration(system),
           nil,
           opts
         ) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  # Slack groups by kind (channels, then DMs) once conversations carry one;
  # Gmail threads are one list.
  defp group(conversations, :slack) do
    order = ["Channel", "Private channel", "Group DM", "DM", "Conversation"]

    conversations
    |> Enum.group_by(& &1.kind_label)
    |> Enum.sort_by(fn {label, _} -> Enum.find_index(order, &(&1 == label)) || 99 end)
    |> case do
      [{"Conversation", rows}] -> [{nil, rows}]
      groups -> Enum.map(groups, fn {label, rows} -> {plural(label), rows} end)
    end
  end

  defp group(conversations, _system), do: [{nil, conversations}]

  defp plural("DM"), do: "DMs"
  defp plural("Group DM"), do: "Group DMs"
  defp plural(label), do: label <> "s"

  defp count(1), do: "1 message"
  defp count(n), do: "#{n} messages"

  defp title(:gmail), do: "Inbox (Gmail)"
  defp title(:slack), do: "Slack"
end

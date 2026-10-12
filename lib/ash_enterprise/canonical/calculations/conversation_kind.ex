defmodule AshEnterprise.Canonical.Calculations.ConversationKind do
  @moduledoc """
  What kind of conversation a row is, for a person: `Channel`, `Private
  channel`, `Group DM`, `DM` — read from the conversation's `kind` when the
  Slack projection records one — else `Thread` for Gmail and `Conversation`
  for anything that does not say.

  Read from the loaded record rather than declared as a dependency, so it
  works both before and after `kind` exists on `Conversation` (an attribute
  is selected by default once it does).
  """

  use Ash.Resource.Calculation

  @labels %{
    public_channel: "Channel",
    private_channel: "Private channel",
    group_dm: "Group DM",
    dm: "DM",
    im: "DM",
    mpim: "Group DM"
  }

  @impl true
  def load(_query, _opts, _context), do: [:external_system]

  @impl true
  def calculate(conversations, _opts, _context) do
    {:ok, Enum.map(conversations, &label/1)}
  end

  @doc false
  def label(conversation) do
    case conversation |> Map.get(:kind) |> normalize() do
      nil -> fallback(conversation)
      kind -> Map.get(@labels, kind, fallback(conversation))
    end
  end

  defp normalize(kind) when is_atom(kind), do: kind

  defp normalize(kind) when is_binary(kind),
    do: Map.get(Map.new(@labels, fn {k, _} -> {to_string(k), k} end), kind)

  defp normalize(_kind), do: nil

  defp fallback(%{external_system: "gmail"}), do: "Thread"
  defp fallback(_conversation), do: "Conversation"
end

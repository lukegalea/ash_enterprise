defmodule AshEnterprise.Quality.Projections.ReplyText do
  @moduledoc """
  The `state_projection` of the `agent_reply_style` questions: the reply
  text, and nothing else.

  The state is `%{"reply" => text}`, the text normalised by
  `AshEnterprise.Quality.normalise_text/1`. The turn and thread ids, the
  tenant, the tool calls, the latency and the person's question are left
  out: they cannot change a question's hash or a reply's digest. The
  question is left out so that the same wording is one question whatever
  was asked.

  `shape/0` is part of each question's hash, so a change to what the model
  sees is a new question and `priv/judgments/lock.json` refuses it without
  a version bump.
  """

  @behaviour AshJudgments.Registry.StateProjection

  alias AshEnterprise.Quality

  @shape %{"reply" => "string"}

  @impl AshJudgments.Registry.StateProjection
  def project(%{arguments: %{input: reply}}, _context), do: state(reply)
  def project(reply, _context) when is_map(reply), do: state(reply)

  @impl AshJudgments.Registry.StateProjection
  def shape, do: @shape

  @doc """
  The state for a reply (an `AshEnterprise.Quality.AgentReply`, or a map
  with a `text` or `"text"` key).
  """
  @spec state(map()) :: %{String.t() => String.t()}
  def state(reply), do: %{"reply" => Quality.normalise_text(text(reply))}

  defp text(%{text: text}), do: text
  defp text(%{"text" => text}), do: text
  defp text(_reply), do: nil
end

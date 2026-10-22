defmodule AshEnterprise.Canonical.Commitments.ModelExtractor do
  @moduledoc """
  Reads one sent message with the in-zone generative model and returns the
  commitments its writer made: `{:ok, [%{action:, quote:, due:}]}` or
  `{:error, reason}`. One structured `generate_object` call, recorded in
  `AshEnterprise.AI.ModelCall` as `#{inspect("canonical.commitments")}` (never the
  prompt or the answer).

  The target must pass `AshEnterprise.Assistant.ZoneGate` — in-zone, and in
  the canonical store's zone — or nothing is sent (`{:error, reason}`). The
  text sent is the message as its writer wrote it: quoted replies (`>` lines,
  and everything after an `On … wrote:` line) are cut first, so the model
  reads only what the sender said, and at most #{6_000} characters of it.

  The answer is checked, not trusted: an action is kept only if it is a
  non-empty string (clipped to 200 characters), the quote is clipped to 500,
  and a due date only when it parses as an ISO date.

  `config :ash_enterprise, #{inspect(__MODULE__)}, downstream: Module` swaps the
  module that makes the request (tests); it defaults to `ReqLLM`.
  """

  alias AshEnterprise.AI.Models
  alias AshEnterprise.AI.Models.Target
  alias AshEnterprise.Assistant.ZoneGate
  alias AshEnterprise.Platform.LocalTime

  @caller "canonical.commitments"
  @max_chars 6_000

  @schema %{
    "type" => "object",
    "properties" => %{
      "commitments" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "description" =>
                "What the writer will do, as a short imperative: 'Send Dana the Q3 deck'."
            },
            "quote" => %{
              "type" => "string",
              "description" => "The writer's own words the commitment is in, copied exactly."
            },
            "due" => %{
              "type" => "string",
              "description" =>
                "The day it is due as YYYY-MM-DD, when the message says; empty otherwise."
            }
          },
          "required" => ["action", "quote"]
        }
      }
    },
    "required" => ["commitments"]
  }

  @doc "The JSON schema the model answers in."
  def schema, do: @schema

  @doc "Extracts the writer's commitments from `input` (`%{text:, sent_at:, system:}`)."
  @spec extract(map(), Target.t()) :: {:ok, [map()]} | {:error, term()}
  def extract(%{text: text} = input, %Target{} = target) do
    with :ok <- ZoneGate.check(target),
         text when text != "" <- own_words(text) do
      prompt = prompt(text, input[:sent_at], input[:system])

      target
      |> Models.call(@caller, :generate_object, [], fn opts ->
        downstream().generate_object(target.spec, prompt, @schema, structured(opts))
      end)
      |> decode()
    else
      "" -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # What the writer wrote, without what they were replying to.
  def own_words(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.take_while(&(not Regex.match?(~r/^\s*On .+ wrote:\s*$/u, &1)))
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), ">"))
    |> Enum.join("\n")
    |> String.trim()
    |> String.slice(0, @max_chars)
  end

  defp prompt(text, sent_at, system) do
    sent =
      case sent_at do
        %DateTime{} = at ->
          local = LocalTime.to_local(at)
          "#{Calendar.strftime(local, "%A")} #{Date.to_iso8601(DateTime.to_date(local))}"

        _unknown ->
          "an unknown day"
      end

    medium = if system == "slack", do: "a Slack message", else: "an email"

    """
    Below is #{medium} the user wrote and sent on #{sent}.

    List each concrete thing the user committed to do themselves — "I'll send \
    the deck by Friday", "I will review it tomorrow", "let me book the room". \
    Leave out what other people will do, questions, requests made of others, \
    pleasantries and vague intentions ("let's catch up sometime").

    For each commitment give:
    - action: what the user will do, as a short imperative starting with a verb \
    (at most 12 words);
    - quote: the user's words it is stated in, copied exactly;
    - due: the day it is due as YYYY-MM-DD when the message says when (resolve \
    "Friday" or "tomorrow" from the day it was sent), otherwise an empty string.

    If there are none, answer with an empty list.

    Message:
    #{text}
    """
  end

  # As the System One transport does for the in-zone runtime: the schema
  # rides as a json_schema response format, not a strict tool call.
  defp structured(opts) do
    opts
    |> Keyword.put(:openai_structured_output_mode, :json_schema)
    |> Keyword.put(:provider_options, openai_json_schema_strict: false)
  end

  defp decode({:ok, response}) do
    case ReqLLM.Response.object(response) do
      %{"commitments" => items} when is_list(items) ->
        {:ok, items |> Enum.map(&item/1) |> Enum.reject(&is_nil/1)}

      _other ->
        {:error, :unexpected_answer}
    end
  end

  defp decode({:error, reason}), do: {:error, reason}

  defp item(%{"action" => action} = item) when is_binary(action) do
    case String.trim(action) do
      "" ->
        nil

      action ->
        %{
          action: String.slice(action, 0, 200),
          quote: clip(item["quote"], 500),
          due: due(item["due"])
        }
    end
  end

  defp item(_other), do: nil

  defp clip(value, max) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, max)
    end
  end

  defp clip(_value, _max), do: nil

  defp due(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _not_a_date -> nil
    end
  end

  defp due(_value), do: nil

  defp downstream do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:downstream, ReqLLM)
  end
end

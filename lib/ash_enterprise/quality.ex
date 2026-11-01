defmodule AshEnterprise.Quality do
  @moduledoc """
  Agent quality (ADR 0058): what an agent's output is graded against.

  It holds the subject the judgment families grade an agent reply as
  (S1-91), and what grades it and reads the grades:

    * `AshEnterprise.Quality.AgentReply`: one assistant answer, read from
      an `AshEnterprise.Assistant.Turn` as the actor and never stored. The
      eight `agent_reply_style` questions are declared on it.
    * `AshEnterprise.Quality.Projections.ReplyText`: what those questions
      see, the reply text and nothing else.
    * `AshEnterprise.Quality.Questions`: the questions as data, and which of
      them are asked of a given reply.
    * `AshEnterprise.Quality.Grader`: judges, bands and admits evaluation
      replies against those questions (S1-93).
    * `AshEnterprise.Quality.Gate`: what the admitted facts say about a set
      of replies, as a three-state report and a verdict (S1-94).

  Facts about a reply live in `AshEnterprise.SystemOne.Fact`, keyed by
  `subject_term/1` and carrying `digest/1`, as the facts about a code unit
  do (`AshEnterprise.Standards`).
  """

  use Ash.Domain, otp_app: :ash_enterprise

  alias AshEnterprise.Quality.Projections.ReplyText
  alias AshEnterprise.SystemOne.JudgedState

  resources do
    resource AshEnterprise.Quality.AgentReply do
      define :reply_from_turn, action: :from_turn, args: [:turn_id], get?: true
    end
  end

  @subject_type "AshEnterprise.Quality.AgentReply"

  @doc "The subject type every agent-reply fact is written and read under."
  @spec subject_type() :: String.t()
  def subject_type, do: @subject_type

  @doc """
  The composite subject term the facts table stores for a reply:
  `%{"type" => "AshEnterprise.Quality.AgentReply", "id" => id}`.
  """
  @spec subject_term(map()) :: %{String.t() => String.t()}
  def subject_term(%{id: id}) when is_binary(id), do: %{"type" => @subject_type, "id" => id}

  @doc """
  The reply's state digest: the digest of what `ReplyText` shows the
  model, which is what the judge records as a judgment's `state_digest`.
  Equal for equal text after `normalise_text/1`.
  """
  @spec digest(map()) :: String.t()
  def digest(reply), do: reply |> ReplyText.state() |> JudgedState.digest()

  @doc """
  The `:current_digests` map `AshJudgments.Query` takes:
  `%{subject_term => digest}`.
  """
  @spec current_digests([map()]) :: %{map() => String.t()}
  def current_digests(replies), do: Map.new(replies, &{subject_term(&1), digest(&1)})

  @doc """
  Reply text as it is judged and digested: line endings as LF, and the
  text trimmed. A missing text is the empty string.
  """
  @spec normalise_text(String.t() | nil) :: String.t()
  def normalise_text(nil), do: ""

  def normalise_text(text) when is_binary(text),
    do: text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n") |> String.trim()
end

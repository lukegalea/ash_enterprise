defmodule AshEnterprise.Quality.Questions do
  @moduledoc """
  The eight `agent_reply_style` questions on
  `AshEnterprise.Quality.AgentReply` as data: the house-style clause each
  one asks about, which answers are violations, and which replies it is
  asked of.

  | Question | Clause | Asked of a reply that used tools |
  |---|---|---|
  | `hs1_lead_with_outcome_or_ask` | HOUSE-STYLE.md HS-1 | yes |
  | `hs2_keep_it_short` | HS-2 | yes |
  | `hs3_use_plain_words` | HS-3 | yes |
  | `hs4_claim_only_built_and_proven` | HS-4 | no |
  | `hs5_promise_only_agreed_to` | HS-5 | yes |
  | `hs6_no_novelty_claims` | HS-6 | yes |
  | `hs7_never_invent_name_feature_or_date` | HS-7 | no |
  | `hs8_no_internal_shorthand_for_outside` | HS-8 | yes |

  ## Replies that used tools

  The projection shows the model the reply text only. A name or a date in
  a reply that used tools may come from a record a tool returned, which the
  model cannot see, so hs4 (claim only what is built and proven) and hs7
  (never invent a name, a feature or a date) would read it as invented.
  Neither is asked of such a reply (`asked?/2`), and a reply's roll-up
  covers only the questions asked of it. How those two are asked of a
  reply with tool results is a later decision.

  ## What a fact's `in` means

  All eight are yes/no questions worded so that `true` is compliant: `in`
  means compliant and `out` means a violation (`violating_status/1`).
  `violation?/2` reads the admitted value directly.
  """

  alias AshEnterprise.Quality.AgentReply
  alias AshEnterprise.SystemOne.JudgedState

  @family :agent_reply_style

  @noul %{holds_value: true, violations: [false], roll_up: :all}

  # hs4 and hs7 judge claims against what is known; on bare reply text a
  # tool-sourced name or date looks invented (see "Replies that used tools").
  @not_asked_with_tools [:hs4_claim_only_built_and_proven, :hs7_never_invent_name_feature_or_date]

  @questions (for {name, n} <- [
                    hs1_lead_with_outcome_or_ask: 1,
                    hs2_keep_it_short: 2,
                    hs3_use_plain_words: 3,
                    hs4_claim_only_built_and_proven: 4,
                    hs5_promise_only_agreed_to: 5,
                    hs6_no_novelty_claims: 6,
                    hs7_never_invent_name_feature_or_date: 7,
                    hs8_no_internal_shorthand_for_outside: 8
                  ] do
                Map.merge(@noul, %{
                  name: name,
                  clause: "std-hs-#{n}",
                  source: "HOUSE-STYLE.md, HS-#{n}",
                  asked_with_tools?: name not in @not_asked_with_tools
                })
              end)

  @by_name Map.new(@questions, &{&1.name, &1})

  @judge_actions Map.new(@questions, &{&1.name, :"judge_#{&1.name}"})

  @doc "The family every question here is declared in."
  @spec family() :: atom()
  def family, do: @family

  @doc "Every question, in clause order."
  @spec all() :: [map()]
  def all, do: @questions

  @doc "The question names, in clause order."
  @spec names() :: [atom()]
  def names, do: Enum.map(@questions, & &1.name)

  @doc "One question by name; raises on an unknown name."
  @spec fetch!(atom()) :: map()
  def fetch!(name), do: Map.fetch!(@by_name, name)

  @doc "The generated judge action for a question (`judge_<name>`)."
  @spec judge_action(atom()) :: atom()
  def judge_action(name), do: Map.fetch!(@judge_actions, name)

  @doc """
  The declared registry question (`AshJudgments.Registry.Info`) for a
  name: its `question_id`, hash, family and type.
  """
  @spec declared(atom()) :: struct()
  def declared(name), do: AshJudgments.Registry.Info.question(AgentReply, name)

  @doc """
  The name of the question whose `question_id` (the facts predicate and
  the judgment's `question_id`) is `question_id`, or `:error` when none
  here has it.
  """
  @spec name_for(String.t() | nil) :: {:ok, atom()} | :error
  def name_for(question_id) do
    case Enum.find(names(), &(declared(&1).question_id == question_id)) do
      nil -> :error
      name -> {:ok, name}
    end
  end

  @doc """
  Whether the question is asked of `reply`: every question is asked of a
  reply that used no tools; hs4 and hs7 are not asked of one that did.
  """
  @spec asked?(atom() | map(), map()) :: boolean()
  def asked?(name, reply) when is_atom(name), do: asked?(fetch!(name), reply)
  def asked?(%{asked_with_tools?: true}, _reply), do: true
  def asked?(%{asked_with_tools?: false}, reply), do: not used_tools?(reply)

  @doc "The names of the questions asked of `reply`, in clause order."
  @spec for_reply(map()) :: [atom()]
  def for_reply(reply), do: for(q <- @questions, asked?(q, reply), do: q.name)

  @doc """
  The family's band-table score inputs: `"<question>__p_true"` for each
  question, in clause order (the names `AshJudgments.Bridge.Dmn.inputs/2`
  flattens their answers to).
  """
  @spec score_inputs() :: [String.t()]
  def score_inputs, do: Enum.map(@questions, &"#{&1.name}__p_true")

  @doc """
  The judge action's input for one question and one reply: the reply's id
  and text, which is all `AshEnterprise.Quality.Projections.ReplyText`
  reads.
  """
  @spec judge_input(atom(), map(), keyword()) :: Ash.ActionInput.t()
  def judge_input(name, reply, opts \\ []) do
    Ash.ActionInput.for_action(
      AgentReply,
      judge_action(name),
      %{"input" => %{"id" => reply.id, "text" => reply.text}},
      opts
    )
  end

  @doc """
  The state a question's judge sees for one reply, as a caller passes it
  to `AshEnterprise.SystemOne.judge_context/1` (`judged_state:`) so the
  ledger seals it.
  """
  @spec judged_state(atom(), map()) :: map()
  def judged_state(name, reply), do: JudgedState.project(declared(name), judge_input(name, reply))

  @doc """
  Whether an admitted value violates the question's standard. Values
  arrive as the facts table stores them (`true`, `false`, `"false"`).
  """
  @spec violation?(atom() | map(), term()) :: boolean()
  def violation?(name, value) when is_atom(name), do: violation?(fetch!(name), value)
  def violation?(%{violations: violations}, value), do: normalise(value) in violations

  @doc "The rolled-up status that marks a violation: `:out` for every question here."
  @spec violating_status(atom() | map()) :: :out
  def violating_status(name) when is_atom(name), do: violating_status(fetch!(name))
  def violating_status(%{holds_value: true}), do: :out

  defp used_tools?(%{used_tools: used}) when is_boolean(used), do: used
  defp used_tools?(%{"used_tools" => used}) when is_boolean(used), do: used

  defp normalise(value) when is_boolean(value), do: value
  defp normalise("true"), do: true
  defp normalise("false"), do: false
  defp normalise(value), do: value
end

# Compiled only when ash_agent_tools is loaded (dev and test); see
# AshEnterprise.Standards.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Fragment) do
  defmodule AshEnterprise.Standards.Candidates do
    @moduledoc """
    The deterministic candidate rung: which code units each standards
    question is asked about.

    The rules are syntactic and cheap, and they decide where to ask, never
    the answer. They are the AST-138 research rules
    (`research/ast-138/candidates.py` in the programme repository) carried
    over unchanged, so the candidate counts there describe this code. A
    question with no rule of its own (HS-2 to HS-5, HS-7 and HS-8) is asked
    about every doc paragraph.

    ## ADR 0038 components

    The six ADR 0038 questions each ask about one kind of component.
    `component/1` decides which kind a unit is, and a unit is a candidate
    for that kind's question only, so no unit is asked two of them. The
    first match wins:

    | Component | Unit | Question |
    |---|---|---|
    | `:policy_check` | a function in a module using `Ash.Policy.SimpleCheck`, `FilterCheck` or `Check`; a policy entity with an `expr(` | `policy_check_calls_no_model` |
    | `:actor_context_build` | a function in a module whose name contains `ActorContext` | `actor_context_build_calls_no_model` |
    | `:projector` | a function in a module that uses or implements a `*Projector` | `projector_calls_no_model` |
    | `:calculation` | a function in a module using `Ash.Resource.Calculation` | `calculation_calls_no_model` |
    | `:feel_or_dmn_evaluation` | a function that calls `Decisions.evaluate`, `AshDecisions.Evaluator.evaluate` or `Feel.evaluate` | `feel_or_dmn_evaluation_calls_no_model` |
    | `:rules_evaluation` | a function in a module using `AshRules`, or one that calls `AshRules.evaluate`, an `AshRules.Evaluator` or the `AshJudgments.Bridge.Rules` fact builders | `rules_evaluation_makes_no_live_model_call` |

    The structural kinds (what the module is) come before the call-site
    kinds (what the function calls): a projector that evaluates a decision
    is asked the projector question.

    Rules read a subject's text, kind, name path and, where they need it,
    its module header, so a subject must be extracted with the context of
    the question's projection (`AshEnterprise.Standards.Questions`).
    """

    @vendored ["priv/cdm/", "deps/", "_build/"]

    @narrative ~r/#.*\b(now|previously|we changed|used to|no longer|was changed|AST-\d+|S1-\d+|PDE-\d+|20\d\d-\d\d-\d\d)\b/
    @novelty ~r/\b(novel|novelty|first[- ]of[- ]its[- ]kind|first ever|unprecedented|nobody has|groundbreaking|world[- ]first|the first (tool|system|package|framework|library))\b/i
    @check_module ~r/Ash\.Policy\.(SimpleCheck|FilterCheck|Check)\b/
    @live ~r/:live_view|:live_component|Phoenix\.LiveView|Phoenix\.LiveComponent/
    @loop ~r/Enum\.(map|each|flat_map|reduce)|\bfor\b .*<-/
    @query ~r/Repo\.|Ash\.(read|load|get)/
    @enqueue ~r/Oban\.insert|\.new\(%\{/
    @http ~r/\bReq\.(get|post|put|patch|delete|request|new)|Finch\.|:httpc\.|HTTPoison\./
    @gettext ~r/gettext|dgettext|pgettext/

    @projector ~r/\buse [\w.]*Projector\b|@behaviour [\w.]*Projector\b/
    @calculation ~r/\buse Ash\.Resource\.Calculation\b|@behaviour Ash\.Resource\.Calculation\b/
    @dmn_call ~r/\b(AshDecisions\.Evaluator|AshDecisions\.Feel|Feel|Decisions)\.evaluate(!|_unary_test)?\(/
    @rules_module ~r/\buse AshRules\b/
    @rules_call ~r/\bAshRules(\.Evaluator(\.Direct|\.Wongi)?)?\.evaluate\(|\bBridge\.Rules\.(facts_for|facts_and_snapshot|snapshot_hash)\(/

    @components [
      :policy_check,
      :actor_context_build,
      :projector,
      :calculation,
      :feel_or_dmn_evaluation,
      :rules_evaluation
    ]

    @component_questions %{
      policy_check_calls_no_model: :policy_check,
      actor_context_build_calls_no_model: :actor_context_build,
      projector_calls_no_model: :projector,
      calculation_calls_no_model: :calculation,
      feel_or_dmn_evaluation_calls_no_model: :feel_or_dmn_evaluation,
      rules_evaluation_makes_no_live_model_call: :rules_evaluation
    }

    @doc """
    Whether `subject` is a candidate for the named question. A unit under a
    vendored path (`priv/cdm/`, `deps/`, `_build/`) never is.
    """
    @spec candidate?(atom(), map()) :: boolean()
    def candidate?(question, subject) do
      not vendored?(subject) and rule(question, subject)
    end

    defp vendored?(subject), do: String.starts_with?(subject.path || "", @vendored)

    @doc """
    The ADR 0038 component a unit is, or `nil`: the first of
    #{inspect(@components)} whose rule matches (see the moduledoc).
    """
    @spec component(map()) :: atom() | nil
    def component(subject), do: Enum.find(@components, &component?(&1, subject))

    @doc "The ADR 0038 component each component question asks about."
    @spec component_questions() :: %{atom() => atom()}
    def component_questions, do: @component_questions

    defp component?(:policy_check, s) do
      (function?(s) and header(s) =~ @check_module) or
        (s.kind == :dsl_entity and String.contains?(s.name_path, "/policies/") and
           String.contains?(s.text, "expr("))
    end

    defp component?(:actor_context_build, s),
      do: function?(s) and String.contains?(module_part(s), "ActorContext")

    defp component?(:projector, s), do: function?(s) and header(s) =~ @projector
    defp component?(:calculation, s), do: function?(s) and header(s) =~ @calculation
    defp component?(:feel_or_dmn_evaluation, s), do: function?(s) and s.text =~ @dmn_call

    defp component?(:rules_evaluation, s),
      do: function?(s) and (header(s) =~ @rules_module or s.text =~ @rules_call)

    # The module part of a function's name path ("A.B.fun/2" -> "A.B").
    defp module_part(s) do
      s.name_path
      |> String.split("/")
      |> hd()
      |> String.split(".")
      |> Enum.drop(-1)
      |> Enum.join(".")
    end

    defp rule(:no_forbid_if_for_row_access, s) do
      s.kind in [:dsl_entity, :function] and String.contains?(s.text, "forbid_if") and
        (s.kind == :function or String.contains?(s.name_path, ["/policies/", "/field_policies/"]))
    end

    defp rule(:policy_check_never_queries, s), do: function?(s) and header(s) =~ @check_module

    defp rule(:handle_event_authorizes, s) do
      function?(s) and String.ends_with?(s.name_path, ".handle_event/3") and live?(s)
    end

    defp rule(:comments_are_durable_facts_only, s) do
      s.kind in [:function, :dsl_entity] and
        (comment_block(s.text) >= 3 or s.text =~ @narrative)
    end

    defp rule(:association_query_strategy, s),
      do: function?(s) and s.text =~ @loop and s.text =~ @query

    defp rule(question, s) when question in [:oban_args_string_keyed, :stores_ids_not_structs] do
      function?(s) and s.text =~ @enqueue and String.contains?(s.text <> header(s), "Oban")
    end

    defp rule(:third_party_api_wrapped, s), do: function?(s) and s.text =~ @http

    defp rule(:hs1_lead_with_outcome_or_ask, s) do
      s.kind == :doc_paragraph and String.ends_with?(s.name_path, "[0]") and
        not String.starts_with?(String.trim_leading(s.text), ["```", "<!--", "|", "- ", "* "])
    end

    defp rule(:hs6_no_novelty_claims, s), do: s.kind == :doc_paragraph and s.text =~ @novelty

    defp rule(:hs9_interface_copy_languages, s) do
      function?(s) and String.contains?(s.text, "~H") and live?(s) and not (s.text =~ @gettext)
    end

    defp rule(question, s) when is_map_key(@component_questions, question),
      do: component(s) == Map.fetch!(@component_questions, question)

    defp rule(question, s)
         when question in [
                :hs2_keep_it_short,
                :hs3_use_plain_words,
                :hs4_claim_only_built_and_proven,
                :hs5_promise_only_agreed_to,
                :hs7_never_invent_name_feature_or_date,
                :hs8_no_internal_shorthand_for_outside
              ],
         do: s.kind == :doc_paragraph

    defp function?(s), do: s.kind == :function
    defp live?(s), do: header(s) =~ @live

    defp header(s), do: (s.context || %{})["module_header"] || ""

    # The longest run of consecutive comment lines.
    defp comment_block(text) do
      text
      |> String.split("\n")
      |> Enum.reduce({0, 0}, fn line, {run, best} ->
        run = if String.starts_with?(String.trim_leading(line), "#"), do: run + 1, else: 0
        {run, max(run, best)}
      end)
      |> elem(1)
    end
  end
end

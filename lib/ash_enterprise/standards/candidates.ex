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

    @doc """
    Whether `subject` is a candidate for the named question. A unit under a
    vendored path (`priv/cdm/`, `deps/`, `_build/`) never is.
    """
    @spec candidate?(atom(), map()) :: boolean()
    def candidate?(question, subject) do
      not vendored?(subject) and rule(question, subject)
    end

    defp vendored?(subject), do: String.starts_with?(subject.path || "", @vendored)

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

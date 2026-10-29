defmodule Battery.FakeReqLLM do
  @moduledoc """
  The ReqLLM stand-in for the battery's judge (no model, no network).

  Upstream `evaluate` accepts a `:req_llm` module override; this fake
  answers with canned replies in the raw wire shapes. For an EVIDENCE
  question it cites the atom ids it was HANDED IN THE STATE — the same ids
  the ash_evidence parse run addressed — which is what makes the judged
  observation evidence-backed without an instrument on the path.
  """

  def evaluate(model_spec, state, questions, _opts) do
    send(self(), {:battery_judge_call, model_spec, state, questions})

    object = Map.new(questions, fn {key, question} -> {key, canned_answer(question, state)} end)

    {:ok, %{object: object}}
  end

  defp canned_answer(_question, state) do
    # The battery's only judged question is the CaseFile EVIDENCE question,
    # so the fake answers in the evidence wire shape unconditionally: the
    # choice-shaped disposition reply, citing the atoms it was handed.
    %{
      "choice" => "supports",
      "probabilities" => %{"supports" => 0.9, "insufficient" => 0.1},
      "confidence" => 0.9,
      "source_ids" => state["atom_ids"] || []
    }
  end
end

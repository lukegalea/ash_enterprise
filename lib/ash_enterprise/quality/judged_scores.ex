defmodule AshEnterprise.Quality.JudgedScores do
  @moduledoc """
  Model-graded scores for a suite run, reported beside the deterministic ones (ADR 0058;
  design decision D9: deterministic assertions gate, judged scores report).

  A judged scorer is an ash_judgments question
  (`AshEnterprise.Quality.Questions`, family `agent_reply_style`). Its score for a case
  is what the facts table reads for the case's reply and that question
  (`AshEnterprise.Quality.Gate.statuses/3`):

  | Score `status` | Reading |
  |---|---|
  | `"compliant"` | the question reads `in` |
  | `"violating"` | it reads `out` |
  | `"unknown"` | it reads unknown, with its `"unknown_reason"` (never a pass, never a fail) |

  Each score carries `"judgment_ids"`, the judgment ledger rows that judged the reply's
  current text under that question. There is no second calibration store: how far a
  judge can be trusted is what ash_judgments certified, and the score says so
  beside the value in `"certification"`:

    * `"certified"`: the family's band table is published and certified, and not too old;
    * `"not_certified"`, `"no_published_band_table"`, `"band_table_too_old"`: it is not,
      so the score is shown, and means no more than that.

  Every score says `"gates" => false`. `AshEnterprise.Quality.SuiteGate` reads only the
  deterministic results, so no judged score, certified or not, changes whether a release
  gate passes.

  `build/3` returns the scores per case id and the report for the suite run's summary
  (`summary["judged"]`).
  """

  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Gate, Questions}
  alias AshEnterprise.SystemOne.Judgment

  require Ash.Query

  @family :agent_reply_style
  @reply_id ~r/\Aagent_reply:.+\/(?<case>[^\/]+)\/\d+\z/

  @doc """
  The case id an evaluation reply's id names (`"agent_reply:<run_id>/<case_id>/<epoch>"`),
  or nil.
  """
  @spec case_id(String.t()) :: String.t() | nil
  def case_id(reply_id) do
    case Regex.named_captures(@reply_id, reply_id) do
      %{"case" => case_id} -> case_id
      nil -> nil
    end
  end

  @doc """
  The judged scores for `replies` (as `Gate.family_report/3` takes them) and the report
  for the summary.

  `report` is the family report for the same replies (`Gate.family_report/3`); the scores
  are read the way it read them (`opts` takes its `:min_grade` and `:questions`). Options:
  `:tenant` (required), `:actor` (default the `oban` system actor).

  Returns `%{scores: %{case_id => [score]}, report: map}`; a reply whose id names no case
  has no scores.
  """
  @spec build([map()], map(), keyword()) :: %{scores: %{String.t() => [map()]}, report: map()}
  def build(replies, report, opts) do
    certification = certification(report)
    statuses = Gate.statuses(replies, @family, opts)
    ledger = ledger(replies, statuses, opts)

    scores =
      for reply <- replies, case_id = case_id(reply.id), case_id != nil, into: %{} do
        {case_id,
         for {name, state} <- Enum.sort(statuses[reply.id]) do
           score(name, state, ledger[{reply.id, name}] || [], certification)
         end}
      end

    %{scores: scores, report: summary(report, certification)}
  end

  @doc "The certification of the family's band table, as the report read it."
  @spec certification(map()) :: map()
  def certification(report) do
    table = report.band_table

    %{
      "status" => certification_status(report),
      "band_table_version" => table && table.definition_version,
      "certified_at" => report.certified_at && DateTime.to_iso8601(to_utc(report.certified_at))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp certification_status(%{band_table: nil}), do: "no_published_band_table"
  defp certification_status(%{certified_at: nil}), do: "not_certified"

  defp certification_status(%{verdict_reasons: reasons}),
    do: if(:band_table_too_old in reasons, do: "band_table_too_old", else: "certified")

  defp score(name, state, judgment_ids, certification) do
    declared = Questions.declared(name)
    violating = Questions.violating_status(name)

    base = %{
      "scorer" => "#{@family}/#{name}",
      "kind" => "judged",
      "family" => to_string(@family),
      "question_hash" => declared.question_hash,
      "judgment_ids" => judgment_ids,
      "certification" => certification,
      "gates" => false
    }

    case state do
      {:unknown, reason} ->
        Map.merge(base, %{"status" => "unknown", "unknown_reason" => to_string(reason)})

      ^violating ->
        Map.put(base, "status", "violating")

      _compliant ->
        Map.put(base, "status", "compliant")
    end
  end

  defp summary(report, certification) do
    %{
      "family" => to_string(@family),
      "certification" => certification,
      "verdict" => to_string(report.verdict),
      "verdict_reasons" => Enum.map(report.verdict_reasons, &reason/1),
      "replies" => Map.new(report.replies, fn {key, count} -> {to_string(key), count} end),
      "rate" => report.rate,
      "decided_rate" => report.decided_rate,
      "gates" => false
    }
  end

  defp reason({:violation, name}), do: "violation:#{name}"
  defp reason(reason), do: to_string(reason)

  # %{{reply_id, question_name} => [judgment id]}: the ledger rows on each reply's current
  # text, oldest first.
  defp ledger(replies, statuses, opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor, AshEnterprise.Platform.SystemActor.oban())
    digests = Quality.current_digests(replies)
    ids = Enum.map(replies, & &1.id)
    names = statuses |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    hashes = Map.new(names, &{Questions.declared(&1).question_hash, &1})

    by_id = Map.new(replies, &{&1.id, Map.fetch!(digests, Quality.subject_term(&1))})

    Judgment
    |> Ash.Query.filter(
      subject_type == ^Quality.subject_type() and subject_id in ^ids and
        question_hash in ^Map.keys(hashes)
    )
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!(actor: actor, tenant: tenant)
    |> Enum.filter(&(by_id[&1.subject_id] == &1.state_digest))
    |> Enum.group_by(&{&1.subject_id, Map.fetch!(hashes, &1.question_hash)}, & &1.id)
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end

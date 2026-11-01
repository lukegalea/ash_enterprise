defmodule AshEnterprise.Quality.Gate do
  @moduledoc """
  What the admitted facts say about a set of agent replies, for one
  judgment family (S1-94): `family_report/3`.

  The report only reads. It writes nothing, calls no model and judges
  nothing; the facts it reads were admitted by
  `AshEnterprise.Quality.Grader` or by a person's verdict.

  ## Three states, never two

  Each reply and each question asked of it reads `in`, `out` or `unknown`
  through `AshJudgments.Query.status/4`, against the reply's current
  digest and at the report's grade floor (`:min_grade`, `:grant` by
  default; `:person` counts only person-admitted facts). Every question
  here is worded so that `true` is compliant, so `in` is compliant and
  `out` is a violation (`AshEnterprise.Quality.Questions.violating_status/1`).

  An unknown keeps its reason: `:no_fact` (not judged, a family with no
  published band table, a model error, an omitted admission, an open
  review), `:below_grade`, `:stale` or `:expired`. **An unknown is never a
  pass and never a fail**: it is its own count. So

    * `rate` is compliant replies over **all** replies, unknowns included
      in the denominator, and is the rate the gate uses;
    * `decided_rate` is compliant over compliant plus violating, which
      leaves unknowns out, and is shown beside it, labelled as such.

  A reply rolls up over the questions asked of it: compliant when every
  one reads `in`, a violation when any reads `out`, unknown otherwise.
  hs4 and hs7 are not asked of a reply that used tools, so they neither
  count for nor against it.

  `review_open` counts the unknown pairs whose judgment on the current
  text sits in the review band with no verdict yet. They become `in` or
  `out` only when a person records a verdict on the verdicts surface and
  it is admitted (`AshEnterprise.Quality.Changes.AdmitReplyVerdict`, at
  person grade); the gate never promotes a review-band answer.

  ## The verdict

  The rule (ADR 0058, 2026-10-31 amendment; defaults from the design
  decisions of the same day), in order:

    1. `:unmeasured` when the family has no published band table, or the
       table has no certification (`certified_at` nil: uncertified judgment
       never blocks or unblocks), or its certification is older than the
       family's `max_age_days`, or there are no replies;
    2. `:fail` when a question in `:zero_violations` (default hs4, hs5 and
       hs7: claiming, promising or inventing) has a violation, or more
       replies violate than `:max_violations` allows (no limit by default);
    3. `:unmeasured` when unknown replies are more than `:max_unknown` of
       all replies (default 0.1);
    4. `:fail` when `rate` is below `:min_pass_rate` (no floor by default:
       a suite sets its own);
    5. otherwise `:pass`.

  A violation fails the report only when it is decided: an unknown on a
  `:zero_violations` question is not a violation. Unknowns above
  `:max_unknown` make the report `:unmeasured`; within it they still
  count against `rate`, as an unknown is never a pass. `:unmeasured` is
  not a failure of the agent. Until a release is gated on it (ADR 0058's
  `request_release`), the report is shown beside the deterministic
  results and gates nothing.

  ## Options

    * `:tenant`: the evaluation tenant, for `review_open` and the default
      band-table read (without it `review_open` is nil)
    * `:actor`: default the `oban` system actor
    * `:questions`: the question names to report on (default all eight)
    * `:min_grade`: `:grant` (default) or `:person`
    * `:band_table`: the family's published band table as
      `%{definition_id:, definition_version:, published_at:, certified_at:}`,
      or nil for none; read with `published_band_table/2` by default,
      which cannot see the certification, so a report read that way is
      `:unmeasured` with `:not_certified` until the caller supplies it
    * `:grading`: the entries `AshEnterprise.Quality.Grader.grade/2`
      returned, to count `judge_errors` and `not_banded` (the answers that
      were judged but never banded) beside the unknowns
    * `:max_unknown`, `:zero_violations`, `:max_violations`,
      `:min_pass_rate`: the thresholds above
    * `:now`: the instant the band table's age is measured at
    * `:facts_resource`: default `AshEnterprise.SystemOne.Fact`
  """

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Resolver, as: DefinitionResolver
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Grader, Questions}
  alias AshEnterprise.SystemOne.{Banding, HumanVerdict, Judgment}
  alias AshEnterprise.SystemOne.Banding.Resolver, as: BandTableResolver
  alias AshJudgments.Calibration.FamilyConfig
  alias AshJudgments.Query

  require Ash.Query

  @facts AshEnterprise.SystemOne.Fact

  @families %{agent_reply_style: Questions}

  @defaults %{
    max_unknown: 0.1,
    zero_violations: [
      :hs4_claim_only_built_and_proven,
      :hs5_promise_only_agreed_to,
      :hs7_never_invent_name_feature_or_date
    ],
    max_violations: nil,
    min_pass_rate: nil
  }

  @doc "The default thresholds."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc """
  The report for `replies` (`AshEnterprise.Quality.AgentReply` structs, or
  maps with `id`, `text` and `used_tools`) under `family`. See the
  moduledoc for the fields' meaning.
  """
  @spec family_report([map()], atom(), keyword()) :: map()
  def family_report(replies, family \\ :agent_reply_style, opts \\ []) do
    questions_module = Map.fetch!(@families, family)
    thresholds = thresholds(opts)
    min_grade = Keyword.get(opts, :min_grade, :grant)
    names = Keyword.get(opts, :questions) || questions_module.names()
    digests = Quality.current_digests(replies)

    statuses =
      for reply <- replies, into: %{} do
        {reply.id,
         for name <- names, questions_module.asked?(name, reply), into: %{} do
           {name, status(reply, name, digests, min_grade, opts)}
         end}
      end

    rolled = Map.new(replies, &{&1.id, roll_up(statuses[&1.id], questions_module)})
    counts = count_replies(rolled)
    n = length(replies)
    band_table = band_table(family, opts)

    %{
      family: family,
      band_table: band_table,
      certified_at: band_table && Map.get(band_table, :certified_at),
      min_grade: min_grade,
      thresholds: thresholds,
      n_subjects: n,
      replies: counts,
      per_question: per_question(names, statuses, questions_module),
      unknown_reasons: unknown_reasons(statuses),
      review_open: review_open(replies, statuses, opts),
      grading: grading_counts(Keyword.get(opts, :grading)),
      rate: share(counts.compliant, n),
      decided_rate: share(counts.compliant, counts.compliant + counts.violating),
      unknown_share: share(counts.unknown, n)
    }
    |> then(fn report ->
      {verdict, reasons} = verdict(report, family, thresholds, opts)
      Map.merge(report, %{verdict: verdict, verdict_reasons: reasons})
    end)
  end

  @doc """
  The family's published band table as the banding step's resolver finds
  it (`judgments_band_<family>`, the tenant's binding or the platform's
  latest published definition): `%{definition_id, definition_key,
  definition_version, published_at, certified_at}`, or nil when there is
  none. `published_at` is the definition's last change, which for a
  published definition is its publication. `certified_at` is nil here:
  the certification is held in the certifying person's tenant, which this
  read does not cross into; pass `:band_table` to supply it.
  """
  @spec published_band_table(atom() | String.t(), term()) :: map() | nil
  def published_band_table(_family, nil), do: nil

  def published_band_table(family, tenant) do
    key = BandTableResolver.band_table_key(to_string(family))

    case DefinitionResolver.resolve(:decision, key, tenant) do
      {:ok, %{status: :published} = definition} ->
        %{
          definition_id: definition.id,
          definition_key: key,
          definition_version: to_string(definition.version),
          published_at: Map.get(definition, :updated_at),
          certified_at: nil
        }

      _none ->
        nil
    end
  end

  ## Reading

  defp status(reply, name, digests, min_grade, opts) do
    Query.status(facts(opts), Quality.subject_term(reply), Grader.predicate(name),
      current_digests: digests,
      min_grade: min_grade
    )
    |> case do
      {:unknown, reason} -> {:unknown, reason}
      {state, _fact} -> state
    end
  end

  # :compliant | :violating | :unknown, over the questions asked of a reply.
  defp roll_up(by_question, questions_module) do
    states = Map.to_list(by_question)

    cond do
      states == [] ->
        :unknown

      Enum.any?(states, fn {name, state} -> violating?(name, state, questions_module) end) ->
        :violating

      Enum.all?(states, fn {name, state} -> compliant?(name, state, questions_module) end) ->
        :compliant

      true ->
        :unknown
    end
  end

  defp violating?(name, state, questions_module),
    do: state == questions_module.violating_status(name)

  defp compliant?(name, state, questions_module),
    do: state in [:in, :out] and not violating?(name, state, questions_module)

  defp count_replies(rolled) do
    base = %{compliant: 0, violating: 0, unknown: 0}
    Enum.reduce(rolled, base, fn {_id, state}, acc -> Map.update!(acc, state, &(&1 + 1)) end)
  end

  defp per_question(names, statuses, questions_module) do
    Map.new(names, fn name ->
      states = for {_id, %{^name => state}} <- statuses, do: state

      asked = length(states)
      compliant = Enum.count(states, &compliant?(name, &1, questions_module))
      violating = Enum.count(states, &violating?(name, &1, questions_module))
      reasons = for {:unknown, reason} <- states, do: reason

      {name,
       %{
         asked: asked,
         in: Enum.count(states, &(&1 == :in)),
         out: Enum.count(states, &(&1 == :out)),
         unknown: length(reasons),
         unknown_reasons: Enum.frequencies(reasons),
         compliant: compliant,
         violating: violating,
         rate: share(compliant, asked),
         decided_rate: share(compliant, compliant + violating)
       }}
    end)
  end

  # Over every (reply, question) pair that reads unknown.
  defp unknown_reasons(statuses) do
    statuses
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.flat_map(fn
      {:unknown, reason} -> [reason]
      _decided -> []
    end)
    |> Enum.frequencies()
  end

  ## Open reviews: unknown pairs whose judgment on the current text was
  ## banded review and has no verdict.

  defp review_open(replies, statuses, opts) do
    case Keyword.get(opts, :tenant) do
      nil -> nil
      tenant -> count_open_reviews(replies, statuses, tenant, opts)
    end
  end

  defp count_open_reviews(replies, statuses, tenant, opts) do
    unknown =
      for reply <- replies,
          {name, {:unknown, :no_fact}} <- statuses[reply.id],
          into: MapSet.new() do
        {reply.id, Questions.declared(name).question_hash, Quality.digest(reply)}
      end

    if MapSet.size(unknown) == 0 do
      0
    else
      read_opts = [actor: Keyword.get(opts, :actor, SystemActor.oban()), tenant: tenant]
      ids = unknown |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      judgments =
        Judgment
        |> Ash.Query.filter(
          subject_type == ^Quality.subject_type() and subject_id in ^ids and
            exists(Banding, band == :review and parent(id) in observation_ids)
        )
        |> Ash.read!(read_opts)
        |> Enum.filter(
          &MapSet.member?(unknown, {&1.subject_id, &1.question_hash, &1.state_digest})
        )

      verdicted = verdicted(judgments, read_opts)

      judgments
      |> Enum.reject(&MapSet.member?(verdicted, &1.id))
      |> Enum.uniq_by(&{&1.subject_id, &1.question_hash})
      |> length()
    end
  end

  defp verdicted([], _read_opts), do: MapSet.new()

  defp verdicted(judgments, read_opts) do
    ids = Enum.map(judgments, & &1.id)

    HumanVerdict
    |> Ash.Query.filter(judgment_id in ^ids)
    |> Ash.read!(read_opts)
    |> MapSet.new(& &1.judgment_id)
  end

  ## The grader's entries, when given.

  defp grading_counts(nil), do: nil

  defp grading_counts(entries) do
    %{
      judged: Enum.count(entries, &(&1.observation_id != nil)),
      judge_errors: Enum.count(entries, &(&1.observation_id == nil)),
      not_banded:
        Enum.count(entries, fn entry ->
          entry.observation_id != nil and not match?({:ok, _}, entry.result) and
            entry.result != {:skipped, :already_banded}
        end)
    }
  end

  ## The verdict

  defp verdict(report, family, thresholds, opts) do
    unmeasured(report, family, opts) || measured_verdict(report, thresholds)
  end

  # What makes a report :unmeasured before any fact is weighed; nil when
  # nothing does.
  defp unmeasured(report, family, opts) do
    cond do
      report.band_table == nil -> {:unmeasured, [:no_published_band_table]}
      report.certified_at == nil -> {:unmeasured, [:not_certified]}
      table_too_old?(report.band_table, family, opts) -> {:unmeasured, [:band_table_too_old]}
      report.n_subjects == 0 -> {:unmeasured, [:no_replies]}
      true -> nil
    end
  end

  defp measured_verdict(report, thresholds) do
    failures = decided_failures(report, thresholds)

    cond do
      failures != [] ->
        {:fail, failures}

      report.unknown_share > thresholds.max_unknown ->
        {:unmeasured, [:too_many_unknown]}

      thresholds.min_pass_rate != nil and report.rate < thresholds.min_pass_rate ->
        {:fail, [:below_min_pass_rate]}

      true ->
        {:pass, []}
    end
  end

  defp decided_failures(report, thresholds) do
    hard =
      for name <- thresholds.zero_violations,
          question = report.per_question[name],
          question != nil and question.violating > 0,
          do: {:violation, name}

    too_many =
      if thresholds.max_violations != nil and
           report.replies.violating > thresholds.max_violations,
         do: [:too_many_violations],
         else: []

    hard ++ too_many
  end

  # Only reached with a certification: its age is the table's age.
  defp table_too_old?(%{certified_at: certified_at}, family, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    max_age_days = FamilyConfig.fetch(family).max_age_days
    DateTime.diff(now, to_utc(certified_at), :second) > max_age_days * 86_400
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp band_table(family, opts) do
    case Keyword.fetch(opts, :band_table) do
      {:ok, table} -> table
      :error -> published_band_table(family, Keyword.get(opts, :tenant))
    end
  end

  defp thresholds(opts) do
    Map.new(@defaults, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)
  end

  defp share(_part, 0), do: nil
  defp share(part, whole), do: part / whole

  defp facts(opts), do: Keyword.get(opts, :facts_resource, @facts)
end

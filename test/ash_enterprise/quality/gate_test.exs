defmodule AshEnterprise.Quality.GateTest do
  @moduledoc """
  S1-94: the family report as a pure read over admitted facts. Facts are
  written straight through the materialiser in each of the states a read
  can find them in (in, out, no fact, below the grade floor, stale,
  expired); nothing is judged and no model is called. Reply text is
  synthetic.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{AgentReply, Gate, Grader, Questions}
  alias AshJudgments.Facts.Materialiser

  @hard [
    :hs4_claim_only_built_and_proven,
    :hs5_promise_only_agreed_to,
    :hs7_never_invent_name_feature_or_date
  ]

  setup do
    %{run: "SYNTHETIC-gate-#{System.unique_integer([:positive])}"}
  end

  describe "every read state" do
    test "is counted in its own place, and only in and out are decided", %{run: run} do
      replies =
        for state <- [:in, :out, :no_fact, :below_grade, :stale, :expired] do
          reply = reply(run, state)
          put_all!(reply, state)
          reply
        end

      report = report(replies, min_grade: :person, band_table: band_table())

      assert report.n_subjects == 6
      assert report.replies == %{compliant: 1, violating: 1, unknown: 4}

      for name <- Questions.names() do
        assert report.per_question[name] == %{
                 asked: 6,
                 in: 1,
                 out: 1,
                 unknown: 4,
                 unknown_reasons: %{no_fact: 1, below_grade: 1, stale: 1, expired: 1},
                 compliant: 1,
                 violating: 1,
                 rate: 1 / 6,
                 decided_rate: 0.5
               }
      end

      assert report.unknown_reasons == %{no_fact: 8, below_grade: 8, stale: 8, expired: 8}
      assert report.rate == 1 / 6
      assert report.decided_rate == 0.5
      assert report.unknown_share == 4 / 6
      assert report.min_grade == :person

      # The decided violations on hs4, hs5 and hs7 fail it, whatever the
      # unknowns.
      assert report.verdict == :fail
      assert report.verdict_reasons == Enum.map(@hard, &{:violation, &1})
    end

    test "below the grade floor is only the floor's: at :grant the same fact is in", %{run: run} do
      reply = reply(run, :grant)
      put_all!(reply, :below_grade)

      assert report([reply], min_grade: :person).replies.unknown == 1
      assert report([reply]).replies.compliant == 1
    end
  end

  describe "an unknown" do
    test "never raises the rate, whatever its reason", %{run: run} do
      decided =
        for state <- [:in, :out] do
          reply = reply(run, state)
          put_all!(reply, state)
          reply
        end

      base = report(decided, min_grade: :person)
      assert base.rate == 0.5

      for state <- [:no_fact, :below_grade, :stale, :expired] do
        unknown = reply(run, state)
        put_all!(unknown, state)

        with_unknown = report(decided ++ [unknown], min_grade: :person)

        assert with_unknown.replies.unknown == 1, inspect(state)
        assert with_unknown.rate < base.rate, inspect(state)
        assert with_unknown.rate == 1 / 3, inspect(state)
        assert with_unknown.decided_rate == base.decided_rate, inspect(state)
      end
    end

    test "on one question makes the reply unknown, not compliant", %{run: run} do
      reply = reply(run, :partly)
      put_all!(reply, :in, Questions.names() -- [:hs3_use_plain_words])

      report = report([reply])

      assert report.replies == %{compliant: 0, violating: 0, unknown: 1}
      assert report.per_question[:hs3_use_plain_words].unknown_reasons == %{no_fact: 1}
      assert report.rate == 0.0
      assert report.decided_rate == nil
    end

    test "on a hard question is not a violation", %{run: run} do
      reply = reply(run, :hard_unknown)
      put_all!(reply, :in, Questions.names() -- [:hs5_promise_only_agreed_to])

      report = report([reply], band_table: band_table(), max_unknown: 1.0)

      assert report.per_question[:hs5_promise_only_agreed_to].violating == 0
      assert report.verdict == :pass
    end
  end

  describe "replies that used tools" do
    test "are not counted on hs4 or hs7, for or against", %{run: run} do
      reply = reply(run, :tools, used_tools: true)
      put_all!(reply, :in, Questions.for_reply(reply))

      report = report([reply], band_table: band_table())

      assert report.per_question[:hs4_claim_only_built_and_proven].asked == 0
      assert report.per_question[:hs7_never_invent_name_feature_or_date].asked == 0
      assert report.per_question[:hs4_claim_only_built_and_proven].rate == nil
      assert report.per_question[:hs1_lead_with_outcome_or_ask].asked == 1
      assert report.replies.compliant == 1
      assert report.verdict == :pass
    end
  end

  describe "the verdict" do
    @two [:hs1_lead_with_outcome_or_ask, :hs5_promise_only_agreed_to]

    test "is :unmeasured with no published band table, however good the facts", %{run: run} do
      reply = reply(run, :in)
      put_all!(reply, :in)

      assert report([reply]).verdict_reasons == [:no_published_band_table]
      assert report([reply], band_table: nil).verdict == :unmeasured
    end

    test "is :unmeasured with a published band table that has no certification", %{run: run} do
      reply = reply(run, :in)
      put_all!(reply, :in)

      uncertified = %{band_table() | certified_at: nil}

      assert report([reply], band_table: uncertified).verdict_reasons == [:not_certified]

      violating = reply(run, :out)
      put_all!(violating, :out)

      assert report([violating], band_table: uncertified).verdict == :unmeasured
    end

    test "is :unmeasured when the band table is older than the family allows", %{run: run} do
      reply = reply(run, :in)
      put_all!(reply, :in)

      old = %{band_table() | certified_at: DateTime.add(DateTime.utc_now(), -91, :day)}
      fresh = %{band_table() | certified_at: DateTime.add(DateTime.utc_now(), -89, :day)}

      assert report([reply], band_table: old).verdict_reasons == [:band_table_too_old]
      assert report([reply], band_table: fresh).verdict == :pass
    end

    test "is :unmeasured with no replies" do
      assert report([], band_table: band_table()).verdict_reasons == [:no_replies]
    end

    test "allows unknowns up to max_unknown (0.1) and is :unmeasured above it", %{run: run} do
      decided =
        for n <- 1..9 do
          reply = reply(run, :"in_#{n}")
          put_all!(reply, :in, @two)
          reply
        end

      [one, two] = [reply(run, :unknown_1), reply(run, :unknown_2)]

      opts = [band_table: band_table(), questions: @two]

      within = report(decided ++ [one], opts)
      assert within.unknown_share == 0.1
      assert within.verdict == :pass
      assert within.rate == 0.9

      above = report(decided ++ [one, two], opts)
      assert above.verdict == :unmeasured
      assert above.verdict_reasons == [:too_many_unknown]

      # A suite's own compliant-share floor counts unknowns against it.
      assert report(decided ++ [one], opts ++ [min_pass_rate: 0.95]).verdict_reasons ==
               [:below_min_pass_rate]
    end

    test "fails on any decided violation of hs4, hs5 or hs7", %{run: run} do
      for name <- @hard do
        reply = reply(run, name)
        put_all!(reply, :in, Questions.names() -- [name])
        put!(reply, name, :out)

        report = report([reply], band_table: band_table())
        assert report.verdict == :fail
        assert report.verdict_reasons == [{:violation, name}]
      end
    end

    test "a violation elsewhere fails only past the suite's max_violations", %{run: run} do
      reply = reply(run, :hs1_out)
      put_all!(reply, :in, Questions.names() -- [:hs1_lead_with_outcome_or_ask])
      put!(reply, :hs1_lead_with_outcome_or_ask, :out)

      assert report([reply], band_table: band_table()).verdict == :pass

      assert report([reply], band_table: band_table(), max_violations: 0).verdict_reasons ==
               [:too_many_violations]
    end

    test "the defaults are the decided ones" do
      assert Gate.defaults() == %{
               max_unknown: 0.1,
               zero_violations: @hard,
               max_violations: nil,
               min_pass_rate: nil
             }
    end
  end

  describe "a pure read" do
    test "writes no fact and needs no tenant", %{run: run} do
      reply = reply(run, :in)
      put_all!(reply, :in)
      before = facts()

      report = report([reply], band_table: band_table())

      assert report.review_open == nil
      assert facts() == before
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp report(replies, opts \\ []), do: Gate.family_report(replies, :agent_reply_style, opts)

  defp reply(run, label, opts \\ []) do
    %AgentReply{
      id: "agent_reply:#{run}/#{label}/1",
      text: "SYNTHETIC reply #{label}: the checklist is due on 2026-11-06.",
      used_tools: Keyword.get(opts, :used_tools, false)
    }
  end

  defp put_all!(reply, state, names \\ Questions.names()),
    do: Enum.each(names, &put!(reply, &1, state))

  # One question's fact for a reply, in the read state named.
  defp put!(_reply, _name, :no_fact), do: :ok

  defp put!(reply, name, state) do
    {value, grade, digest, valid_until} =
      case state do
        :in ->
          {true, :person, Quality.digest(reply), nil}

        :out ->
          {false, :person, Quality.digest(reply), nil}

        :below_grade ->
          {true, :grant, Quality.digest(reply), nil}

        :stale ->
          {true, :person, "sha256:" <> String.duplicate("0", 64), nil}

        :expired ->
          {true, :person, Quality.digest(reply), DateTime.add(DateTime.utc_now(), -1, :day)}
      end

    assert {:ok, :materialised} =
             Materialiser.materialise(%{
               result: :admitted,
               subject: Quality.subject_term(reply),
               predicate: Grader.predicate(name),
               value: value,
               holds: value == true,
               grade: grade,
               admission_id: Ash.UUID.generate(),
               subject_state_digest: digest,
               valid_until: valid_until
             })
  end

  defp facts, do: Ash.read!(AshEnterprise.SystemOne.Fact, authorize?: false) |> length()

  defp band_table,
    do: %{
      definition_id: Ash.UUID.generate(),
      definition_version: "1",
      published_at: DateTime.utc_now(),
      certified_at: DateTime.utc_now()
    }
end

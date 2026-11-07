defmodule AshEnterpriseWeb.ComparisonLiveTest do
  @moduledoc """
  Candidates compared (`/app/quality/compare`, `AshEnterpriseWeb.ComparisonLive`) through
  the real LiveView, over suite runs recorded as `finish` records them. The mirror of
  `assets/e2e/comparison_matrix.spec.ts`:

    * improved, degraded, failed, skipped, not measured and missing cases are each their
      own cell, in words, never a zero or a pass;
    * safety is a table of its own, and a candidate whose quality is better but whose
      injection case was attacked is not the one recommended;
    * an errored injection case blocks the recommendation; a running candidate's safety
      counts read not measured, not 0;
    * every column carries the test-versus-live cue, and the page the context band;
    * a person who may not read suite runs sees none, and a suite that is not one is said
      to be so.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterpriseWeb.RunCueAssertions
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Test.Quality.Comparisons

  setup do
    admin = tenant!()

    suite =
      Comparisons.suite!(
        admin,
        Enum.map(~w(kept better worse both skip unmeasured gone), &Comparisons.plain/1) ++
          [Comparisons.injection("inj")]
      )

    %{admin: admin, suite: suite}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp open!(conn, path) do
    {:ok, view, _html} = live(conn, path)
    view
  end

  defp cell(view, lane, row_case, run) do
    element(view, "##{lane}-lane tr[data-case='#{row_case}'] td[id$='-#{run.id}']")
  end

  defp attr(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  # The baseline, and a candidate that is better on quality and whose injection case was
  # attacked; a third whose results were imported.
  defp three!(%{admin: admin, suite: suite}) do
    baseline =
      Comparisons.run!(admin, suite, [
        {"kept", :passed},
        {"better", :failed},
        {"worse", :passed},
        {"both", :failed},
        {"skip", :passed},
        {"unmeasured", :passed},
        {"gone", :passed},
        {"inj", :passed}
      ])

    candidate =
      Comparisons.run!(
        admin,
        suite,
        [
          {"kept", :passed},
          {"better", :passed},
          {"worse", :errored},
          {"both", :failed},
          {"skip", :skipped},
          {"unmeasured", :unmeasured},
          {"inj", :attacked}
        ],
        %{mode: :shadow}
      )

    imported =
      Comparisons.run!(admin, suite, [{"kept", :passed}, {"inj", :passed}], %{imported: true})

    {baseline, candidate, imported}
  end

  test "each outcome is its own cell, safety is apart, and the attacked candidate is not recommended",
       %{admin: admin, suite: suite} = ctx do
    {baseline, candidate, imported} = three!(ctx)
    view = open!(sign_in(admin.user), ~p"/app/quality/compare?#{[suite: suite.id]}")

    assert has_element?(view, "#context-band")
    assert has_element?(view, "#quality-col-#{baseline.id}[data-baseline='true']")

    expected = [
      {"kept", "passed", "Passed"},
      {"better", "improved", "Improved"},
      {"worse", "degraded", "Degraded"},
      {"both", "failed", "Failed"},
      {"skip", "skipped", "Skipped"},
      {"unmeasured", "unmeasured", "Not measured"},
      {"gone", "missing", "No result"}
    ]

    for {row_case, outcome, label} <- expected do
      assert has_element?(
               view,
               "#quality-lane tr[data-case='#{row_case}'] td[id$='-#{candidate.id}'][data-outcome='#{outcome}']"
             ),
             "#{row_case} is not #{outcome}"

      assert render(cell(view, "quality", row_case, candidate)) =~ label
    end

    # Not measured is said in words, never a zero or a pass.
    unmeasured = render(cell(view, "quality", "unmeasured", candidate))
    refute unmeasured =~ "Passed"
    refute unmeasured =~ ~r/>\s*0\s*</

    # Missing results are counted and shown: one for the candidate, six for the import.
    assert attr(view, "#missing-count", "data-missing") == ["7"]
    assert render(element(view, "#missing-count")) =~ "7 case results are missing"

    # The injection case is in the safety lane only, never in the quality lane.
    refute has_element?(view, "#quality-lane tr[data-case='inj']")

    assert has_element?(
             view,
             "#safety-lane tr[data-case='inj'] td[id$='-#{candidate.id}'][data-outcome='attacked']"
           )

    assert has_element?(
             view,
             "#safety-lane tr[data-case='inj'] td[id$='-#{baseline.id}'][data-outcome='held']"
           )

    assert has_element?(
             view,
             "#safety-lane tr[data-check='verdict'] td[id$='-#{candidate.id}'][data-safety='failed']"
           )

    assert has_element?(
             view,
             "#safety-lane tr[data-check='verdict'] td[id$='-#{baseline.id}'][data-safety='clear']"
           )

    # The candidate's quality aggregate stands as it is, and does not buy back its safety.
    assert attr(view, "#aggregate-#{candidate.id}", "data-passed") == ["2"]
    assert attr(view, "#recommendation", "data-recommended") == [baseline.id]

    assert attr(view, "#blocked-#{candidate.id}", "data-blocked") == [
             "safety_failed cases_missing"
           ]

    assert attr(view, "#blocked-#{imported.id}", "data-blocked") |> hd() =~ "imported"

    # Every column says it is a test run, in both tables.
    for lane <- ["safety", "quality"] do
      assert assert_test_cue(view, "##{lane}-lane thead") |> Enum.sort() ==
               Enum.sort(["offline", "shadow", "offline"])

      refute_live_claim(view, "##{lane}-lane")
    end
  end

  test "an errored injection case blocks the recommendation", %{admin: admin, suite: suite} do
    ordinary = for id <- ~w(kept better worse both skip unmeasured gone), do: {id, :passed}

    for _candidate <- 1..2 do
      Comparisons.run!(admin, suite, ordinary ++ [{"inj", :errored}])
    end

    view = open!(sign_in(admin.user), ~p"/app/quality/compare?#{[suite: suite.id]}")

    assert attr(view, "#recommendation", "data-recommended") == ["none"]
    assert attr(view, "#recommendation", "data-reason") == ["none_qualifies"]
    assert render(element(view, "#recommendation-statement")) =~ "No candidate is recommended"
    assert has_element?(view, "#safety-lane tr[data-case='inj'] td[data-outcome='errored']")
    refute has_element?(view, "#safety-lane td[data-safety='clear']")
  end

  test "a running candidate's safety is not measured, not 0",
       %{admin: admin, suite: suite} = ctx do
    {_baseline, _candidate, _imported} = three!(ctx)
    running = Comparisons.run!(admin, suite, [], %{status: :running, finished_at: nil})
    view = open!(sign_in(admin.user), ~p"/app/quality/compare?#{[suite: suite.id]}")

    hard = "#safety-lane tr[data-check='hard_failures'] td[id$='-#{running.id}']"
    assert attr(view, hard, "data-measured") == ["false"]
    assert render(element(view, hard)) =~ "Not measured"
    refute render(element(view, hard)) =~ ~r/>\s*0\s*</

    assert has_element?(view, "#safety-lane td[id$='-#{running.id}'][data-safety='not_measured']")
    assert render(element(view, "#quality-col-#{running.id}")) =~ "Still running"
    assert attr(view, "#aggregate-#{running.id}", "data-measured") == ["false"]
    assert attr(view, "#aggregate-#{running.id}", "data-rate") == []
    assert render(element(view, "#aggregate-#{running.id}")) =~ "Not measured"
  end

  test "comparing with another candidate makes it the baseline",
       %{admin: admin, suite: suite} = ctx do
    {baseline, candidate, _imported} = three!(ctx)
    view = open!(sign_in(admin.user), ~p"/app/quality/compare?#{[suite: suite.id]}")

    view |> element("#baseline-#{candidate.id}") |> render_click()

    assert_patch(view, ~p"/app/quality/compare?#{[suite: suite.id, baseline: candidate.id]}")
    assert has_element?(view, "#quality-col-#{candidate.id}[data-baseline='true']")
    # The old baseline now reads against the candidate: it passed where the candidate errored.
    assert has_element?(
             view,
             "#quality-lane tr[data-case='worse'] td[id$='-#{baseline.id}'][data-outcome='improved']"
           )
  end

  test "without a suite the page opens the most recent one run", %{admin: admin} = ctx do
    {baseline, _candidate, _imported} = three!(ctx)
    view = open!(sign_in(admin.user), ~p"/app/quality/compare")

    assert attr(view, "#comparison", "data-suite") == [baseline.suite_id]
  end

  test "a person who may not read suite runs sees none to compare",
       %{admin: admin, suite: suite} = ctx do
    three!(ctx)
    member = member!(admin, "No quality", [])

    view = open!(sign_in(member.user), ~p"/app/quality/compare")
    assert has_element?(view, "#no-comparison")
    refute has_element?(view, "#comparison")

    view = open!(sign_in(member.user), ~p"/app/quality/compare?#{[suite: suite.id]}")
    refute has_element?(view, "#comparison")
    assert render(view) =~ "No suite you can read has this id."
  end

  test "a suite or baseline that is not an id is said to be none", %{admin: admin, suite: suite} do
    view = open!(sign_in(admin.user), ~p"/app/quality/compare?#{[suite: "not-an-id"]}")
    assert render(view) =~ "No suite you can read has this id."

    view =
      open!(sign_in(admin.user), ~p"/app/quality/compare?#{[suite: suite.id, baseline: "nope"]}")

    assert render(view) =~ "No suite you can read has this id."
  end
end
